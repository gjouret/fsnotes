//
//  TextStorageProcessor.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 26.06.2022.
//  Copyright © 2022 Oleksandr Hlushchenko. All rights reserved.
//

#if os(OSX)
import Cocoa
import AVKit
#else
import UIKit
import AVKit
#endif

#if os(OSX)
/// Attachment cell that centers an image within the full container width.
/// The cell spans the container width so paragraph alignment doesn't matter —
/// centering is handled in the draw method, immune to addTabStops resets.
class CenteredImageCell: NSTextAttachmentCell {
    private let imageSize: NSSize
    private let containerWidth: CGFloat

    init(image: NSImage, imageSize: NSSize, containerWidth: CGFloat) {
        self.imageSize = imageSize
        self.containerWidth = containerWidth
        super.init(imageCell: image)
    }

    required init(coder: NSCoder) {
        self.imageSize = .zero
        self.containerWidth = 400
        super.init(coder: coder)
    }

    override func cellSize() -> NSSize {
        return NSSize(width: containerWidth, height: imageSize.height)
    }

    /// Called by the layout manager with the CURRENT line fragment rect.
    /// This lets us shrink the attachment dynamically when the editor is
    /// resized narrower than the image's intrinsic width.
    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let available = lineFrag.width
        guard imageSize.width > 0, available > 0 else {
            return NSRect(x: 0, y: -2, width: containerWidth, height: imageSize.height)
        }
        // If image is wider than available line-fragment width, scale down proportionally.
        if imageSize.width > available {
            let scale = available / imageSize.width
            return NSRect(x: 0, y: -2, width: available, height: imageSize.height * scale)
        }
        // Image fits; cell spans the available width so it can center horizontally.
        return NSRect(x: 0, y: -2, width: available, height: imageSize.height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let image = self.image else { return }
        // Scale the image to fit the current cellFrame, preserving aspect ratio.
        // cellFrame.height is already the scaled height (from cellFrame(for:...)),
        // so the image's drawn height should match cellFrame.height.
        var drawSize = imageSize
        if drawSize.width > cellFrame.width && drawSize.width > 0 {
            let fitScale = cellFrame.width / drawSize.width
            drawSize = NSSize(width: drawSize.width * fitScale, height: drawSize.height * fitScale)
        }
        let x = cellFrame.origin.x + (cellFrame.width - drawSize.width) / 2
        let drawRect = NSRect(origin: NSPoint(x: x, y: cellFrame.origin.y),
                              size: drawSize)
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0,
                   respectFlipped: true, hints: nil)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        // Don't draw if this attachment is inside a folded region
        if let ts = layoutManager.textStorage,
           charIndex < ts.length,
           ts.attribute(.foldedContent, at: charIndex, effectiveRange: nil) != nil {
            return
        }
        draw(withFrame: cellFrame, in: controlView)
    }

    override func cellBaselineOffset() -> NSPoint {
        return NSPoint(x: 0, y: -2)
    }
}
#endif

class TextStorageProcessor: NSObject, NSTextStorageDelegate, RenderingFlagProvider {
    /// Protocol-based reference — breaks concrete dependency on EditTextView.
    public weak var editorDelegate: EditorDelegate?

    /// Legacy accessor — callers that need the concrete type use this.
    /// Each caller should migrate to editorDelegate over time.
    public var editor: EditTextView? {
        get { return editorDelegate as? EditTextView }
        set { editorDelegate = newValue }
    }

    public var isRendering = false
    /// When true, the block-model pipeline owns rendering. The old
    /// process() pipeline must not run — it would apply syntax colors,
    /// kern, and clear-foreground to storage that has no markdown markers.
    public var blockModelActive = false

    /// Phase 4.4 — when true, `SourceRenderer` owns source-mode rendering.
    /// Storage is already tagged with `.markerRange` runs and appropriate
    /// fonts by `SourceRenderer.render`; `process()` must not run the
    /// legacy `highlightMarkdown` path (which would strip markers and
    /// re-apply conflicting attributes). This flag mirrors
    /// `blockModelActive` for the source-mode view.
    public var sourceRendererActive = false

    // MARK: - Block Array (source-mode + fold/unfold state)

    /// Block array used by fold/unfold and the source-mode rendering
    /// pipeline. In source mode it's populated by `updateBlockModel()`
    /// (driven by `MarkdownBlockParser`). In WYSIWYG mode it's
    /// populated automatically by the `documentProjection` setter via
    /// `rebuildBlocksFromProjection(_:)` — callers no longer invoke a
    /// public sync method (Phase 4.6).
    public var blocks: [MarkdownBlock] = []

    /// Deduplication set for mermaid/math code-block rendering (unrelated
    /// to the sync path; stays).
    private var pendingRenderedBlockIDs = Set<UUID>()

    /// Phase 6 Tier B′ — canonical fold state. Set of storage offsets
    /// (`block.range.location`) for blocks that are currently
    /// collapsed. Storage offset is more stable than block index across
    /// edits above the folded block (inserting a paragraph above a
    /// folded heading shifts indices but not offsets) and matches the
    /// preservation logic that `rebuildBlocksFromProjection` already
    /// uses to carry collapsed state across projection rebuilds.
    ///
    /// `MarkdownBlock.collapsed` is now a dual-written cache that
    /// reflects this set. Internal reads should prefer the offset-keyed
    /// queries below; external readers (`GutterController`, tests)
    /// still read `block.collapsed` until Sub-slice 2 migrates them
    /// to public APIs on this processor.
    private var collapsedStorageOffsets: Set<Int> = []

    /// Is the block at this storage offset currently collapsed?
    public func isCollapsed(storageOffset: Int) -> Bool {
        return collapsedStorageOffsets.contains(storageOffset)
    }

    /// Is the block at this index in `blocks` currently collapsed?
    public func isCollapsed(blockIndex idx: Int) -> Bool {
        guard idx >= 0, idx < blocks.count else { return false }
        return collapsedStorageOffsets.contains(blocks[idx].range.location)
    }

    /// Return the set of block indices that are currently collapsed.
    ///
    /// Computed from the canonical `collapsedStorageOffsets` side-table
    /// + the current `blocks` array. Retained for tests and gutter
    /// readers that index the `blocks` array directly; the canonical
    /// persistence form is `collapsedBlockOffsets` (Phase 6 Tier B′
    /// Sub-slice 3).
    public var collapsedBlockIndices: Set<Int> {
        var indices: Set<Int> = []
        for (i, block) in blocks.enumerated() {
            if collapsedStorageOffsets.contains(block.range.location) {
                indices.insert(i)
            }
        }
        return indices
    }

    /// Canonical offset-keyed fold state — set of `block.range.location`
    /// for blocks currently collapsed. Read by the persistence path
    /// (`Note.cachedFoldState`); stable across edits above the folded
    /// block (Phase 6 Tier B′ Sub-slice 3).
    public var collapsedBlockOffsets: Set<Int> {
        return collapsedStorageOffsets
    }

    /// Canonical render-mode side-table (Phase 6 Tier B′ Sub-slice 4).
    /// Set of `block.range.location` for code blocks currently in
    /// `.rendered` mode (mermaid / math / latex bitmap-swap in
    /// source mode; mermaid/math/latex blocks in WYSIWYG which are
    /// classified by language but rendered via fragment dispatch).
    /// Mirrors the Sub-slice 1 fold-state pattern: offset-keyed for
    /// stability across edits above, dual-written to the legacy
    /// `MarkdownBlock.renderMode` field for external readers.
    private var renderedStorageOffsets: Set<Int> = []

    /// Is the block at this storage offset currently `.rendered`?
    public func isRendered(storageOffset: Int) -> Bool {
        return renderedStorageOffsets.contains(storageOffset)
    }

    /// Is the block at this index in `blocks` currently `.rendered`?
    public func isRendered(blockIndex idx: Int) -> Bool {
        guard idx >= 0, idx < blocks.count else { return false }
        return renderedStorageOffsets.contains(blocks[idx].range.location)
    }

    /// Read-only accessor for the canonical render-mode set, mirroring
    /// `collapsedBlockOffsets`. Public for tests and any future external
    /// reader; production code should prefer the per-block queries.
    public var renderedBlockOffsets: Set<Int> {
        return renderedStorageOffsets
    }

    /// Set the render mode for the block at the given index. Public
    /// entry for external callers (e.g. the click-to-edit rendered-image
    /// handler in `EditTextView+Interaction`). Internally routes through
    /// the side-table mutator so the legacy `MarkdownBlock.renderMode`
    /// field stays in sync.
    public func setRenderMode(
        _ mode: BlockRenderMode, forBlockAt blockIndex: Int
    ) {
        guard blockIndex >= 0, blockIndex < blocks.count else { return }
        let offset = blocks[blockIndex].range.location
        setRendered(
            mode == .rendered,
            storageOffset: offset,
            blockIndex: blockIndex
        )
    }

    /// Set the rendered flag for a block at a given storage offset
    /// (canonical) AND keep the dual-written `MarkdownBlock.renderMode`
    /// field in sync. Called by `rebuildBlocksFromProjection` (WYSIWYG
    /// language-based classification), the async mermaid/math render
    /// callback, and `setRenderMode` (external entry point). External
    /// callers should not invoke this directly.
    fileprivate func setRendered(
        _ rendered: Bool, storageOffset: Int, blockIndex: Int? = nil
    ) {
        if rendered {
            renderedStorageOffsets.insert(storageOffset)
        } else {
            renderedStorageOffsets.remove(storageOffset)
        }
        if let idx = blockIndex, idx >= 0, idx < blocks.count {
            blocks[idx].renderMode = rendered ? .rendered : .source
        }
    }

    /// Re-derive the render-mode side-table from the per-block field.
    /// Called by the source-mode `updateBlockModel` path after the
    /// parser repopulates `blocks` (parser doesn't know about the side
    /// table — until Sub-slice 7 retires the field, the parser's
    /// per-block flag is the canonical state for newly-parsed blocks).
    fileprivate func syncRenderedSideTableFromBlocks() {
        var rendered: Set<Int> = []
        for block in blocks {
            if block.renderMode == .rendered {
                rendered.insert(block.range.location)
            }
        }
        renderedStorageOffsets = rendered
    }

    /// Set the collapsed flag for a block at a given storage offset
    /// (canonical) AND keep the dual-written `MarkdownBlock.collapsed`
    /// cache in sync. Called by `toggleFold` / `restoreCollapsedState`
    /// / `rebuildBlocksFromProjection`. External callers should not
    /// call this directly — go through `toggleFold` /
    /// `foldHeader` / `unfoldHeader`.
    fileprivate func setCollapsed(
        _ collapsed: Bool, storageOffset: Int, blockIndex: Int? = nil
    ) {
        if collapsed {
            collapsedStorageOffsets.insert(storageOffset)
        } else {
            collapsedStorageOffsets.remove(storageOffset)
        }
        // Keep the legacy field in sync for external readers.
        if let idx = blockIndex, idx >= 0, idx < blocks.count {
            blocks[idx].collapsed = collapsed
        }
    }

    /// Restore fold state from a saved set of collapsed storage offsets
    /// (the canonical persistence form, Phase 6 Tier B′ Sub-slice 3).
    /// Walks `blocks` once to find the index whose `range.location`
    /// matches each offset; offsets that no longer correspond to any
    /// block (e.g. the user edited the heading away between sessions)
    /// are silently dropped.
    public func restoreCollapsedState(
        byOffsets offsets: Set<Int>, textStorage: NSTextStorage
    ) {
        var indices: Set<Int> = []
        for (i, block) in blocks.enumerated() {
            if offsets.contains(block.range.location) {
                indices.insert(i)
            }
        }
        restoreCollapsedState(indices, textStorage: textStorage)
    }

    /// Restore fold state from a saved set of collapsed block indices.
    public func restoreCollapsedState(_ indices: Set<Int>, textStorage: NSTextStorage) {
        for idx in indices {
            guard idx < blocks.count else { continue }
            let block = blocks[idx]
            guard !isCollapsed(blockIndex: idx) else { continue }
            // Only fold headings.
            let headerLevel: Int
            switch block.type {
            case .heading(let l): headerLevel = l
            case .headingSetext(let l): headerLevel = l
            default: continue
            }
            let foldRange = foldRangeForHeader(at: idx, level: headerLevel, in: textStorage)
            guard foldRange.length > 0 else { continue }
            setCollapsed(true, storageOffset: block.range.location, blockIndex: idx)
            isRendering = true
            textStorage.addAttribute(.foldedContent, value: true, range: foldRange)
            textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: foldRange)
            isRendering = false
        }
        textStorage.layoutManagers.first?.invalidateLayout(
            forCharacterRange: NSRange(location: 0, length: textStorage.length),
            actualCharacterRange: nil
        )
    }

    /// Code block ranges in source mode (excludes rendered mermaid/math images).
    /// Used by LayoutManager for gray background and by triggerCodeBlockRenderingIfNeeded.
    public var codeBlockRanges: [NSRange] {
        return blocks.compactMap { block in
            if case .codeBlock = block.type, block.renderMode == .source { return block.range }
            return nil
        }
    }

    /// Find the block at a given character index. O(log n).
    public func block(at characterIndex: Int) -> MarkdownBlock? {
        guard let idx = MarkdownBlockParser.blockIndex(in: blocks, containing: characterIndex) else { return nil }
        return blocks[idx]
    }

    /// Count leading tabs and 4-space groups as nesting levels.
    public static func leadingListDepth(_ str: String) -> Int {
        var depth = 0
        var spaces = 0
        for ch in str {
            if ch == "\t" { depth += 1; spaces = 0 }
            else if ch == " " { spaces += 1; if spaces == 4 { depth += 1; spaces = 0 } }
            else { break }
        }
        return depth
    }

    // MARK: - Block Model Sync for Fold/Unfold (Phase 4.6 — private)

    /// Populate the `blocks` array from a `DocumentProjection` so that
    /// fold/unfold (which reads `blocks`) and gutter-draw (which
    /// iterates `blocks` for fold carets + H-badges) work when
    /// `blockModelActive == true`.
    ///
    /// The block-model pipeline bypasses `process()` (which normally
    /// populates `blocks`), so without this rebuild fold operations
    /// would silently no-op in WYSIWYG mode. Phase 4.6 made this method
    /// private and made the `documentProjection` setter call it
    /// automatically — app-layer callers no longer invoke a public sync.
    ///
    /// IMPORTANT: preserves the `collapsed` flag from any existing blocks
    /// keyed by storage offset (NOT by index). Keying by index would
    /// shift fold state to the wrong block when a new block is inserted
    /// above a folded heading: previously-folded index 5 would stay
    /// `collapsed = true` even after a paragraph insertion pushed the
    /// real heading to index 6. Keying by `range.location` instead
    /// means "the block that starts at this storage offset stays folded,"
    /// which tracks the user's intent through inserts and deletes above.
    /// When the folded block itself is edited (its location changes),
    /// the fold is dropped — which is arguably the right semantic: a
    /// user editing the heading content probably wants to see what
    /// they're typing, not keep it folded.
    internal func rebuildBlocksFromProjection(_ projection: DocumentProjection) {
        let doc = projection.document
        let spans = projection.blockSpans
        guard doc.blocks.count == spans.count else {
            blocks = []
            // Side-table is offset-keyed; surviving offsets stay valid
            // across rebuild even when blocks is empty during a guard
            // failure. Don't clear it here — toggleFold writes it.
            return
        }

        // The canonical fold state lives in `collapsedStorageOffsets`
        // (offset-keyed), so it survives projection rebuilds without
        // needing a per-rebuild snapshot. Drop offsets that no longer
        // correspond to any block in the new projection (i.e. the user
        // edited away the folded heading). Phase 6 Tier B′ Sub-slice 4
        // applies the same intersection to the render-mode side-table
        // so it survives WYSIWYG-path rebuilds; the language-based
        // classification below re-establishes the rendered set for any
        // mermaid/math/latex blocks that survived.
        let liveOffsets = Set(spans.map { $0.location })
        collapsedStorageOffsets.formIntersection(liveOffsets)
        renderedStorageOffsets.formIntersection(liveOffsets)

        var newBlocks: [MarkdownBlock] = []
        newBlocks.reserveCapacity(doc.blocks.count)
        for (i, block) in doc.blocks.enumerated() {
            var mb = makeBlockEntry(block: block, span: spans[i], projection: projection)
            if collapsedStorageOffsets.contains(spans[i].location) {
                mb.collapsed = true
            }
            // WYSIWYG language-based render classification: mermaid /
            // math / latex are kept off the gray-background gate via
            // `codeBlockRanges`, which filters on
            // `renderMode == .source`. Side-table is the canonical
            // store; legacy field is dual-written through `setRendered`.
            if case .codeBlock(let lang, _, _) = block,
               let l = lang?.lowercased(),
               l == "mermaid" || l == "math" || l == "latex" {
                renderedStorageOffsets.insert(spans[i].location)
                mb.renderMode = .rendered
            } else if renderedStorageOffsets.contains(spans[i].location) {
                // Side-table entry that survived intersection (e.g. a
                // source-mode rendered block whose offset persists in
                // a hybrid scenario). Keep the field aligned.
                mb.renderMode = .rendered
            }
            newBlocks.append(mb)
        }
        blocks = newBlocks
    }

    /// Build a single `MarkdownBlock` entry from a `Document.Block` + its
    /// rendered span. Phase 6 Tier B′ Sub-slice 4: render-mode
    /// classification (mermaid/math/latex by language) moved up to
    /// `rebuildBlocksFromProjection` so the side-table is the
    /// canonical state. This helper now only emits the structural fields.
    private func makeBlockEntry(block: Block, span: NSRange, projection: DocumentProjection) -> MarkdownBlock {
        let blockType: MarkdownBlockType
        switch block {
        case .heading(let level, _):
            blockType = .heading(level: level)
        case .paragraph:
            // Check if this paragraph's rendered content looks like a
            // markdown table (lines starting/ending with `|` and a
            // separator row). If so, tag it as .table so renderTables()
            // can pick it up and overlay the table widget.
            let content = projection.attributed.attributedSubstring(from: span).string
            if Self.looksLikeTable(content) {
                blockType = .table
            } else {
                blockType = .paragraph
            }
        case .codeBlock(let lang, _, _):
            blockType = .codeBlock(language: lang)
        case .list(let items, _):
            // Determine list type from first item
            if items.first?.checkbox != nil {
                blockType = .todoItem(checked: items.first?.isChecked ?? false)
            } else if let marker = items.first?.marker,
                      marker == "-" || marker == "*" || marker == "+" {
                blockType = .unorderedList
            } else {
                blockType = .orderedList
            }
        case .blockquote:
            blockType = .blockquote
        case .horizontalRule:
            blockType = .horizontalRule
        case .htmlBlock:
            blockType = .paragraph  // HTML blocks render as plain text blocks
        case .blankLine:
            blockType = .empty
        case .table:
            blockType = .table
        }

        var mb = MarkdownBlock(
            type: blockType,
            range: span,
            contentRange: span
        )
        // Carry canonical markdown for table blocks. The widget path
        // consuming this has been deleted (T2-h); keeping the field
        // populated for any remaining source-mode MarkdownBlock
        // consumers. Phase 4.2 drops the per-block `raw` cache, so we
        // rebuild canonically on demand.
        if case .table(let header, let alignments, let rows, _) = block {
            mb.rawMarkdown = EditingOps.rebuildTableRaw(
                header: header, alignments: alignments, rows: rows
            )
        }
        return mb
    }

    /// Heuristic: does the text content look like a markdown table?
    /// Requires at least 2 lines starting with `|`, and a separator line
    /// containing `|--` or `|:--` patterns.
    private static func looksLikeTable(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return false }
        // First line must start with |
        guard lines[0].trimmingCharacters(in: .whitespaces).hasPrefix("|") else { return false }
        // Must have a separator row (|--|, |:--|, etc.)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") && trimmed.contains("--") {
                return true
            }
        }
        return false
    }

    // MARK: - Header Fold/Unfold

    /// Toggle fold state for the header block at the given index in `blocks`.
    public func toggleFold(headerBlockIndex idx: Int, textStorage: NSTextStorage) {
        guard idx < blocks.count else { return }
        let header = blocks[idx]

        let headerLevel: Int
        switch header.type {
        case .heading(let l): headerLevel = l
        case .headingSetext(let l): headerLevel = l
        default: return
        }

        let foldRange = foldRangeForHeader(at: idx, level: headerLevel, in: textStorage)
        guard foldRange.length > 0 else { return }

        isRendering = true
        textStorage.beginEditing()

        if isCollapsed(blockIndex: idx) {
            // Unfold: remove fold marker. Rendering gate in LayoutManager handles the rest.
            textStorage.removeAttribute(.foldedContent, range: foldRange)
            textStorage.removeAttribute(.foregroundColor, range: foldRange)
            setCollapsed(false, storageOffset: header.range.location, blockIndex: idx)
            textStorage.endEditing()
            isRendering = false

            if blockModelActive {
                // Block-model path: the rendered text already has correct
                // attributes from DocumentRenderer. We just need to restore
                // them after removing the fold's clear-foreground override.
                // Trigger a re-render of the affected range by re-splicing
                // the projection's attributed string for the fold range.
                if let editTextView = editor as? EditTextView,
                   let projection = editTextView.documentProjection {
                    let attrSource = projection.attributed
                    let safeEnd = min(NSMaxRange(foldRange), attrSource.length)
                    let safeStart = min(foldRange.location, safeEnd)
                    let safeRange = NSRange(location: safeStart, length: safeEnd - safeStart)
                    if safeRange.length > 0 {
                        let originalAttrs = attrSource.attributedSubstring(from: safeRange)
                        // Attribute-only refresh: walk each run and
                        // call `setAttributes` to copy the projection's
                        // attributes onto storage. The Document hasn't
                        // changed — only presentation state needs to
                        // be reset (clearing the collapsed
                        // foreground override). Because nothing
                        // triggers `.editedCharacters`, the Phase 5a
                        // assertion (gated on
                        // `editedMask.contains(.editedCharacters)`)
                        // is never tested — no
                        // `performingLegacyStorageWrite` wrapper
                        // needed.
                        isRendering = true
                        textStorage.beginEditing()
                        originalAttrs.enumerateAttributes(
                            in: NSRange(location: 0, length: originalAttrs.length),
                            options: []
                        ) { attrs, runRange, _ in
                            let absRange = NSRange(
                                location: safeRange.location + runRange.location,
                                length: runRange.length
                            )
                            textStorage.setAttributes(attrs, range: absRange)
                        }
                        textStorage.endEditing()
                        isRendering = false
                    }
                }
            } else if sourceRendererActive {
                // Phase 4.4: source-mode path uses `SourceRenderer`.
                // Re-parse the full markdown from storage, re-render,
                // and copy attributes onto the unfolded range so markers
                // reclaim their tag + coloring.
                reapplySourceRendererAttributes(
                    textStorage: textStorage,
                    range: foldRange
                )
            } else {
                // Legacy safety fallback — retained for the rare path
                // where source-mode fill hasn't activated SourceRenderer
                // yet (e.g. early boot). Applies only plain paragraph
                // style + body font, mirroring what SourceRenderer would
                // have tagged had it run. No markdown syntax coloring —
                // that's the `SourceRenderer` path's job.
                let paragraphRange = (textStorage.string as NSString).paragraphRange(for: foldRange)
                textStorage.updateParagraphStyle(range: paragraphRange)
            }
            editor?.needsDisplay = true
        } else {
            setCollapsed(true, storageOffset: header.range.location, blockIndex: idx)
            textStorage.endEditing()
            // Set fold attributes AFTER endEditing so process()/highlightMarkdown
            // doesn't strip them during the editing session's processEditing callback.
            isRendering = true
            textStorage.addAttribute(.foldedContent, value: true, range: foldRange)
            textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: foldRange)
            isRendering = false
            // Hide live subviews — they draw independently of LayoutManager.
            // InlinePDFView renders outside LayoutManager's fold gate, so
            // it must be hidden explicitly. (Native tables render via
            // TK2 `TableLayoutFragment`, which is fold-aware — no
            // separate subview hiding needed.)
            if let textView = editor {
                for subview in textView.subviews {
                    if !subview.isHidden,
                       String(describing: type(of: subview)) == "InlinePDFView" {
                        subview.isHidden = true
                    }
                }
            }
        }

        // Invalidate layout for the fold range so the rendering gate takes effect
        textStorage.layoutManagers.first?.invalidateLayout(
            forCharacterRange: foldRange, actualCharacterRange: nil)
        editor?.needsDisplay = true

        // Invalidate layout so zero-height lines take effect
        textStorage.layoutManagers.first?.invalidateLayout(
            forCharacterRange: foldRange, actualCharacterRange: nil)

        // Phase 2f.1 — under TK2 the TK1 layout managers list is empty so
        // the invalidations above are no-ops. Invalidate the TK2 layout
        // stack directly so the content-storage delegate re-dispatches
        // the affected paragraphs (folded → `FoldedElement` → zero-height
        // `FoldedLayoutFragment`; unfolded → normal block-model element).
        //
        // Bug #55: invalidate the HEADING'S paragraph too, not just the
        // fold range below it. `HeadingLayoutFragment.drawFoldedIndicator`
        // peeks at the char immediately following the heading element
        // range for `.foldedContent` to decide whether to paint the
        // `[...]` chip. When `toggleFold` flips that attribute, the
        // heading's fragment isn't invalidated by the fold-range call —
        // its draw doesn't re-run until the next layout pass triggered
        // by scroll. Invalidating the heading line forces the redraw.
        //
        // Bug #54: also invalidate a wider range covering the heading,
        // its trailing newline, AND the full fold range below. Bullets
        // and todo checkboxes in the fold range are attachments whose
        // `NSTextAttachmentViewProvider`s get cached on `TableLayoutFragment`
        // / paragraph fragments. A narrow invalidation of just the
        // attachment-character offsets doesn't always trigger
        // `loadView()` to re-run; expanding to the wider range, then
        // forcing a full TextKit 2 re-layout via the layout manager,
        // does.
        if let editTextView = editor as? EditTextView {
            // Compute the heading line's range so the chip-painter
            // fragment gets re-drawn.
            let nsString = textStorage.string as NSString
            let headerLineRange = nsString.lineRange(
                for: NSRange(location: header.range.location, length: 0)
            )
            // Union: heading line + fold range. Use the broader span
            // to force every attachment view provider in either region
            // to reload.
            let unionStart = min(headerLineRange.location, foldRange.location)
            let unionEnd = max(
                NSMaxRange(headerLineRange), NSMaxRange(foldRange)
            )
            let unionRange = NSRange(
                location: unionStart, length: unionEnd - unionStart
            )
            editTextView.invalidateTextKit2Layout(forCharacterRange: unionRange)

            // Force every attachment in the fold range to drop its
            // cached view provider so `loadView()` runs fresh on the
            // next layout pass. Without this step, `BulletAttachmentViewProvider`
            // / `CheckboxAttachmentViewProvider` re-use the previous
            // `view` (created during the pre-fold render) — and that
            // view never gets re-positioned, so bullets visually
            // disappear after unfold even though the attachment runs
            // are intact in storage.
            textStorage.enumerateAttribute(
                .attachment,
                in: foldRange,
                options: []
            ) { value, _, _ in
                guard let attachment = value as? NSTextAttachment else {
                    return
                }
                // Replacing the image with the same image triggers
                // TK2's attachment-bounds-changed path, which clears
                // the cached view provider. The image identity check
                // is implementation-defined, so we use a fresh
                // transparent placeholder of the same size.
                let size = attachment.bounds.size
                if size.width > 0, size.height > 0 {
                    let img = NSImage(size: size, flipped: false) { _ in true }
                    attachment.image = img
                }
            }
        }

        // RC5: Persist fold state to the note so it survives note
        // switches. Phase 6 Tier B′ Sub-slice 3: write the canonical
        // offset-keyed form directly — no index conversion at the
        // persistence boundary.
        if let note = editor?.note {
            note.cachedFoldState = collapsedStorageOffsets
        }
    }

    /// Find the range to fold: from end of the header line to the next header
    /// with the same level, matching the folding spec literally.
    private func foldRangeForHeader(at idx: Int, level: Int, in textStorage: NSTextStorage) -> NSRange {
        let header = blocks[idx]
        let string = textStorage.string as NSString

        // Fold starts after the header's line (including newline)
        let headerLineRange = string.paragraphRange(for: NSRange(location: header.range.location, length: 0))
        let foldStart = NSMaxRange(headerLineRange)
        guard foldStart < string.length else { return NSRange(location: foldStart, length: 0) }

        // Follow the folding spec literally:
        // stop only at the next header with the same level, regardless of
        // whether that header is ATX or Setext. Horizontal rules must not
        // affect folding.
        var foldEnd = string.length
        findEnd: for i in (idx + 1)..<blocks.count {
            switch blocks[i].type {
            case .heading(let l) where l == level:
                foldEnd = blocks[i].range.location
                break findEnd
            case .headingSetext(let l) where l == level:
                foldEnd = blocks[i].range.location
                break findEnd
            default:
                continue
            }
        }

        return NSRange(location: foldStart, length: foldEnd - foldStart)
    }

    /// Fold the header block at `idx` if it is currently expanded. No-op if
    /// already collapsed.
    public func foldHeader(headerBlockIndex idx: Int, textStorage: NSTextStorage) {
        guard idx < blocks.count, !isCollapsed(blockIndex: idx) else { return }
        toggleFold(headerBlockIndex: idx, textStorage: textStorage)
    }

    /// Unfold the header block at `idx` if it is currently collapsed. No-op if
    /// already expanded.
    public func unfoldHeader(headerBlockIndex idx: Int, textStorage: NSTextStorage) {
        guard idx < blocks.count, isCollapsed(blockIndex: idx) else { return }
        toggleFold(headerBlockIndex: idx, textStorage: textStorage)
    }

    /// Fold all headers in the note.
    /// Process deepest headers first (highest level number) so nested fold ranges
    /// are calculated before their parent headers fold over them.
    public func foldAll(textStorage: NSTextStorage) {
        // Collect header indices with their levels
        var headers: [(index: Int, level: Int)] = []
        for i in 0..<blocks.count {
            switch blocks[i].type {
            case .heading(let l): headers.append((i, l))
            case .headingSetext(let l): headers.append((i, l))
            default: break
            }
        }
        // Sort by level descending (deepest first), then by position descending
        headers.sort { ($0.level, -$0.index) > ($1.level, -$1.index) }
        for h in headers {
            if !isCollapsed(blockIndex: h.index) {
                toggleFold(headerBlockIndex: h.index, textStorage: textStorage)
            }
        }
    }

    /// Unfold all headers in the note.
    public func unfoldAll(textStorage: NSTextStorage) {
        for i in 0..<blocks.count {
            switch blocks[i].type {
            case .heading, .headingSetext:
                if isCollapsed(blockIndex: i) {
                    toggleFold(headerBlockIndex: i, textStorage: textStorage)
                }
            default: break
            }
        }
    }

    /// Find the header block index for a character position.
    public func headerBlockIndex(at charIndex: Int) -> Int? {
        for (i, block) in blocks.enumerated() {
            switch block.type {
            case .heading, .headingSetext:
                if block.range.contains(charIndex) || block.range.location == charIndex {
                    return i
                }
            default: break
            }
        }
        return nil
    }

#if os(iOS)
    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorage.EditActions,
        range editedRange: NSRange,
        changeInLength delta: Int) {

        guard editedMask != .editedAttributes else { return }
        process(textStorage: textStorage, range: editedRange, changeInLength: delta)
    }
#else
    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int) {

        #if DEBUG
        // Phase 5a single-write-path enforcement.
        //
        // Design intent: every character mutation of the editor's
        // content storage in block-model WYSIWYG mode should route
        // through exactly one of the three authorized scopes
        // (`applyDocumentEdit`, `fill`, or the explicitly-flagged
        // legacy escape hatch). If the assertion below fires, a
        // call site is mutating storage outside those scopes — which
        // is the class of bug 5a exists to prevent (Phase 3
        // `applyDocumentEdit` being bypassed by direct storage
        // writes, leaving `Document ↔ NSTextContentStorage` out of
        // sync).
        //
        // Source-mode is out of scope: while `sourceRendererActive`
        // is true, `NSTextContentStorage` IS the source of truth and
        // user keystrokes mutate it directly (AppKit's default text
        // handling). The 5a contract applies only to WYSIWYG
        // (`blockModelActive && !sourceRendererActive`).
        //
        // Release builds compile this entire block out.
        if editedMask.contains(.editedCharacters) &&
           blockModelActive &&
           !sourceRendererActive &&
           !StorageWriteGuard.isAnyAuthorized &&
           !compositionAllows(editedRange: editedRange) {
            let symbols = Thread.callStackSymbols.prefix(12).joined(separator: "\n  ")
            assertionFailure("""
                Phase 5a violation: NSTextContentStorage character mutation \
                happened in block-model WYSIWYG mode outside an authorized \
                scope. Route through DocumentEditApplier.applyDocumentEdit, \
                or wrap in StorageWriteGuard.performingFill / \
                performingLegacyStorageWrite if genuinely legacy.
                editedRange=\(editedRange) \
                editedMask=\(editedMask.rawValue) \
                delta=\(delta)
                Call stack (top 12):
                  \(symbols)
                """)
        }
        #endif

        guard editedMask != .editedAttributes else { return }
        process(textStorage: textStorage, range: editedRange, changeInLength: delta)

        // Force redraw after any character edit so gutter icons update
        // (previously only triggered on deletions, missing new headers)
        if editedMask.contains(.editedCharacters) {
            if let layoutManager = textStorage.layoutManagers.first,
               let textContainer = layoutManager.textContainers.first,
               let textView = textContainer.textView {
                textView.needsDisplay = true
            }
        }
    }

    /// Phase 5e — sanctioned exemption to the 5a single-write-path
    /// rule. Returns true when an active IME composition is in flight
    /// AND `editedRange` lies entirely inside the session's
    /// `markedRange`. Marked-text writes by AppKit's default
    /// `NSTextInputClient` machinery go through this path: they bypass
    /// `shouldChangeText` and `applyDocumentEdit`, but they are
    /// permitted because on commit (`unmarkText` / `insertText`
    /// targeting the marked range) the whole composed run is folded
    /// back into `Document` as one authorized `EditContract`.
    ///
    /// Reads `editor?.compositionSession` — the per-editor state
    /// stored via `objc_setAssociatedObject`. In tests or at any
    /// moment where the editor reference is nil, returns `false` (no
    /// exemption), matching the assertion's previous behavior.
    ///
    /// The exemption is NOT wrapped in `StorageWriteGuard`: composition
    /// is not "legacy" — it is a permanent, documented architectural
    /// exemption (per Phase 5e brief §3). Body delegates to the pure
    /// predicate `compositionAllowsEdit(editedRange:session:)` so
    /// unit tests can exercise the policy without an editor.
    private func compositionAllows(editedRange: NSRange) -> Bool {
        guard let editor = self.editor else { return false }
        guard editor.compositionSession.isActive else { return false }
        return compositionAllowsEdit(
            editedRange: editedRange,
            session: editor.compositionSession
        )
    }
#endif

    /// Rendering pipeline. Runs ONLY when the block-model pipeline is
    /// not driving this edit. When `blockModelActive==true`,
    /// rendering is handled by `DocumentRenderer` + `EditingOps`.
    /// When `sourceRendererActive==true`, source-mode marker coloring is
    /// handled by re-rendering via `SourceRenderer` and copying
    /// attributes onto the edited range.
    private func process(textStorage: NSTextStorage, range editedRange: NSRange, changeInLength delta: Int) {
        guard let note = editor?.note, textStorage.length > 0 else { return }
        guard !isRendering else { return }

        // Block-model pipeline owns rendering — bail out entirely.
        if blockModelActive {
            return
        }

        defer {
            loadImages(textStorage: textStorage, checkRange: editedRange)

            // Block-aware paragraph styles (spacing, indentation).
            if !blocks.isEmpty {
                let nsString = textStorage.string as NSString
                let paragraphRange = expandedParagraphRange(for: editedRange, in: nsString)
                phase5_paragraphStyles(textStorage: textStorage, range: paragraphRange)
            } else {
                textStorage.updateParagraphStyle(range: editedRange)
            }
        }

        if note.content.length == textStorage.length && (
            note.content.string.fnv1a == note.cacheHash
        ) { return }

        let previousBlocks = blocks
        updateBlockModel(textStorage: textStorage, editedRange: editedRange, delta: delta)

        let renderRanges = processingRanges(
            textStorage: textStorage,
            editedRange: editedRange,
            previousBlocks: previousBlocks
        )
        let currentCodeRanges = codeBlockRanges

        for range in renderRanges.markdownRanges {
            let safe = safeRange(range, in: textStorage)
            if sourceRendererActive {
                // Phase 4.4 — re-render the affected paragraph(s) via
                // `SourceRenderer` and copy attributes onto the live
                // storage so markers reclaim their `.markerRange` tag
                // and the body font after typing.
                reapplySourceRendererAttributes(
                    textStorage: textStorage,
                    range: safe
                )
            } else {
                // Fallback: no active renderer for this paragraph yet.
                // Preserves the pre-4.4 behaviour for edge-case fills
                // where source-mode activation raced with the first
                // edit.
                NotesTextProcessor.resetFont(
                    attributedString: textStorage,
                    paragraphRange: safe
                )
            }
        }

        for range in renderRanges.codeRanges {
            // Look up the block's contentRange — the authoritative content
            // bounds from MarkdownBlockParser. Passing it ensures the highlighter
            // touches ONLY code content, never fence characters.
            let contentRange = blocks.first(where: {
                if case .codeBlock = $0.type, $0.range == range { return true }
                return false
            })?.contentRange
            NotesTextProcessor
                .getHighlighter()
                .highlight(in: textStorage, fullRange: range, contentRange: contentRange)
        }
    }

    /// Phase 4.4 — source-mode incremental attribute refresh.
    ///
    /// Parse the full markdown from `textStorage`, re-render via
    /// `SourceRenderer`, and copy the resulting attributes onto the
    /// storage range that intersects `range`. Characters are NOT
    /// replaced (that would invalidate cursor/selection); only the
    /// attribute runs are rewritten.
    ///
    /// This function is safe to call when the parsed-and-re-rendered
    /// string has the same length as `textStorage.string`. When the
    /// lengths differ (extremely rare — happens only when the user
    /// types content that canonicalises to different source text, e.g.
    /// inside a table), we fall back to re-applying base attributes on
    /// the affected range only, so the user does not see a character
    /// splice mid-typing.
    internal func reapplySourceRendererAttributes(
        textStorage: NSTextStorage,
        range: NSRange
    ) {
        guard sourceRendererActive else { return }
        let storageLength = textStorage.length
        guard storageLength > 0 else { return }
        let clampedLocation = max(0, min(range.location, storageLength))
        let clampedLength = max(0, min(range.length, storageLength - clampedLocation))
        let safe = NSRange(location: clampedLocation, length: clampedLength)
        guard safe.length > 0 else { return }

        let markdown = textStorage.string
        let document = MarkdownParser.parse(markdown)
        let rendered = SourceRenderer.render(
            document,
            bodyFont: UserDefaultsManagement.noteFont,
            codeFont: UserDefaultsManagement.codeFont
        )
        // Full-document length match: copy attributes verbatim onto the
        // affected range. This is the fast path and covers every edit
        // that doesn't cross a table's canonical-rebuild boundary.
        if rendered.length == storageLength {
            let priorIsRendering = isRendering
            isRendering = true
            textStorage.beginEditing()
            // Clear marker tags on the affected range so stale tags from
            // the previous render don't linger past content that is no
            // longer a marker (e.g. user deleted the closing `**`).
            textStorage.removeAttribute(.markerRange, range: safe)
            textStorage.removeAttribute(.foregroundColor, range: safe)
            textStorage.removeAttribute(.kern, range: safe)
            // Copy attributes run by run from the rendered string onto
            // the matching storage range.
            rendered.enumerateAttributes(in: safe, options: []) { attrs, subrange, _ in
                textStorage.setAttributes(attrs, range: subrange)
            }
            textStorage.endEditing()
            isRendering = priorIsRendering
            return
        }

        // Fallback: the render produced a different length (a table
        // canonicalised, likely). Leave the typed text alone; just
        // reset to body font so the user sees readable text. A full
        // re-fill on the next blur/save will reconcile.
        let priorIsRendering = isRendering
        isRendering = true
        textStorage.beginEditing()
        textStorage.setAttributes(
            [.font: UserDefaultsManagement.noteFont],
            range: safe
        )
        textStorage.endEditing()
        isRendering = priorIsRendering
    }

    /// Populate the block model from the current text storage.
    /// In shadow mode, this is informational only — no rendering depends on it yet.
    private func updateBlockModel(textStorage: NSTextStorage, editedRange: NSRange, delta: Int) {
        let string = textStorage.string as NSString
        guard string.length > 0 else {
            blocks = []
            renderedStorageOffsets = []
            return
        }

        if editedRange.length == textStorage.length || blocks.isEmpty {
            // Full parse (initial load or first time).
            MarkdownBlockParser.parsePreservingRendered(&blocks, string: string)
        } else {
            // Incremental: adjust existing blocks, re-parse dirty ones
            var dirtyIndices = MarkdownBlockParser.adjustBlocks(&blocks, forEditAt: editedRange.location, delta: delta)

            // Also mark the block at the edit location as dirty
            if let editIdx = MarkdownBlockParser.blockIndex(in: blocks, containing: min(editedRange.location, string.length - 1)) {
                dirtyIndices.insert(editIdx)
            }

            if !dirtyIndices.isEmpty {
                MarkdownBlockParser.reparseBlocks(&blocks, dirtyIndices: dirtyIndices, string: string)
            }
        }

        // Phase 6 Tier B′ Sub-slice 4: re-derive the offset-keyed
        // render-mode side-table from the parser's per-block field.
        // The parser is the canonical source of truth for newly-parsed
        // blocks (until Sub-slice 7 retires the field); this sync
        // keeps the side-table aligned for source-mode reads.
        syncRenderedSideTableFromBlocks()
    }

    private func processingRanges(
        textStorage: NSTextStorage,
        editedRange: NSRange,
        previousBlocks: [MarkdownBlock]
    ) -> (markdownRanges: [NSRange], codeRanges: [NSRange]) {
        if editedRange.length == textStorage.length {
            return (
                markdownRanges: [NSRange(location: 0, length: textStorage.length)],
                codeRanges: codeBlockRanges
            )
        }

        let string = textStorage.string as NSString
        let paragraphRange = expandedParagraphRange(for: editedRange, in: string)
        let previousCodeRanges = codeRanges(in: previousBlocks)
        let currentCodeRanges = codeBlockRanges

        var markdownRanges = [paragraphRange]
        let contextualCodeRanges = (previousCodeRanges + currentCodeRanges).filter { codeRange in
            NSIntersectionRange(codeRange, paragraphRange).length > 0 ||
            NSLocationInRange(editedRange.location, codeRange) ||
            (editedRange.location > 0 && NSLocationInRange(editedRange.location - 1, codeRange))
        }
        markdownRanges.append(contentsOf: contextualCodeRanges)

        let mergedMarkdownRanges = mergeRanges(markdownRanges)
        let codeToHighlight = currentCodeRanges.filter { codeRange in
            mergedMarkdownRanges.contains { NSIntersectionRange($0, codeRange).length > 0 }
        }

        return (markdownRanges: mergedMarkdownRanges, codeRanges: codeToHighlight)
    }

    private func expandedParagraphRange(for editedRange: NSRange, in string: NSString) -> NSRange {
        var paragraphRange = string.paragraphRange(for: editedRange)

        if paragraphRange.location > 0 {
            let prevParaRange = string.paragraphRange(for: NSRange(location: paragraphRange.location - 1, length: 0))
            paragraphRange = NSUnionRange(paragraphRange, prevParaRange)
        }

        let afterEdit = NSMaxRange(paragraphRange)
        if afterEdit < string.length {
            let nextParaRange = string.paragraphRange(for: NSRange(location: afterEdit, length: 0))
            paragraphRange = NSUnionRange(paragraphRange, nextParaRange)
        }

        return paragraphRange
    }

    private func codeRanges(in blocks: [MarkdownBlock]) -> [NSRange] {
        return blocks.compactMap { block in
            if case .codeBlock = block.type, block.renderMode == .source {
                return block.range
            }
            return nil
        }
    }

    private func mergeRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges
            .filter { $0.length > 0 }
            .sorted { lhs, rhs in lhs.location < rhs.location }

        guard var current = sorted.first else { return [] }
        var merged: [NSRange] = []

        for range in sorted.dropFirst() {
            if range.location <= NSMaxRange(current) {
                current = NSUnionRange(current, range)
            } else {
                merged.append(current)
                current = range
            }
        }

        merged.append(current)
        return merged
    }

    // MARK: - Phase 5: Block-Aware Paragraph Styles

    /// Apply paragraph styles based on the block model.
    /// Reads block types to determine spacing, indentation, alignment.
    /// ONLY sets .paragraphStyle — does not touch .foregroundColor, .kern, or .font.
    func phase5_paragraphStyles(textStorage: NSTextStorage, range: NSRange) {
        let font = UserDefaultsManagement.noteFont
        let baseSize = CGFloat(font.pointSize)
        let lineSpacing = CGFloat(UserDefaultsManagement.editorLineSpacing)
        let tabs = textStorage.getTabStops()
        let string = textStorage.string as NSString

        // Get blocks that intersect the range
        let affectedBlocks = MarkdownBlockParser.blocks(in: blocks, intersecting: range)

        for block in affectedBlocks {
            guard block.range.location < string.length,
                  NSMaxRange(block.range) <= string.length else { continue }

            // Find this block's global index for neighbor lookups
            let globalIdx = MarkdownBlockParser.blockIndex(in: blocks, containing: block.range.location)
            let prevBlock = globalIdx.flatMap { $0 > 0 ? blocks[$0 - 1] : nil }
            let nextBlock = globalIdx.flatMap { $0 < blocks.count - 1 ? blocks[$0 + 1] : nil }
            let isFirst = (globalIdx == 0)

            // Process each paragraph within the block
            // CRITICAL: use enclosingRange (3rd param) not substringRange (2nd param)
            // because paragraphSpacing must be set on the \n separator character
            string.enumerateSubstrings(in: block.range, options: .byParagraphs) { [self] value, _, parRange, _ in
                guard let value = value else { return }

                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = lineSpacing
                paragraph.tabStops = tabs
                paragraph.alignment = .left

                // Block-type-specific spacing values for the editor renderer.
                switch block.type {
                case .heading(let level), .headingSetext(let level):
                    switch level {
                    case 1:
                        if !isFirst { paragraph.paragraphSpacingBefore = baseSize * 0.67 }
                        paragraph.paragraphSpacing = baseSize * 0.67
                    case 2:
                        if !isFirst { paragraph.paragraphSpacingBefore = baseSize }
                        paragraph.paragraphSpacing = 16
                    case 3:
                        if !isFirst { paragraph.paragraphSpacingBefore = baseSize * 0.8 }
                        paragraph.paragraphSpacing = 12
                    case 4:
                        if !isFirst { paragraph.paragraphSpacingBefore = baseSize * 0.6 }
                        paragraph.paragraphSpacing = 10
                    case 5:
                        if !isFirst { paragraph.paragraphSpacingBefore = baseSize * 0.5 }
                        paragraph.paragraphSpacing = 8
                    default:
                        if !isFirst { paragraph.paragraphSpacingBefore = baseSize * 0.4 }
                        paragraph.paragraphSpacing = 6
                    }

                case .unorderedList, .orderedList, .todoItem:
                    // Legacy source-mode list indentation:
                    //  - firstLineHeadIndent = slotWidth (constant).
                    //  - headIndent = slotWidth + depth*listStep for wrap alignment.
                    //  - Tab stops placed at depth-based intervals.
                    let depth = Self.leadingListDepth(value)
                    let listStep = baseSize * 4
                    let slotWidth = baseSize * 2
                    let depthIndent = slotWidth + CGFloat(depth) * listStep
                    paragraph.firstLineHeadIndent = slotWidth
                    paragraph.headIndent = depthIndent
                    var listTabStops: [NSTextTab] = []
                    for i in 1...12 {
                        listTabStops.append(NSTextTab(textAlignment: .left,
                                                      location: slotWidth + CGFloat(i) * listStep,
                                                      options: [:]))
                    }
                    paragraph.tabStops = listTabStops
                    paragraph.lineSpacing = 7

                    let isFirstLine = (parRange.location == block.range.location)
                    let isLastLine = (NSMaxRange(parRange) >= NSMaxRange(block.range))
                    if case .todoItem = block.type {
                        let prevIsList = prevBlock.map { self.isListBlock($0.type) } ?? false
                        let nextIsList = nextBlock.map { self.isListBlock($0.type) } ?? false
                        paragraph.paragraphSpacingBefore = prevIsList ? 2 : 0
                        paragraph.paragraphSpacing = nextIsList ? 0 : 16
                    } else {
                        paragraph.paragraphSpacingBefore = isFirstLine ? 0 : 2
                        paragraph.paragraphSpacing = isLastLine ? 16 : 0
                    }

                case .blockquote:
                    // blockquote: vertical bars at depth-1 positions; text must
                    // indent past the last bar per line. baseX=lineFragmentPadding+2,
                    // each bar 4pt wide at 10pt spacing — so text must start past
                    // 2 + depth*10 + 5pt gap + a bit of padding. Use depth*10 + 20.
                    var depth = 0
                    for ch in value { if ch == ">" { depth += 1 } else if ch == " " { continue } else { break } }
                    // Bar extends to baseX + (depth-1)*10 + 4 from container leading edge.
                    // Add ~6pt gap after the last bar for readability.
                    let qIndent = CGFloat(max(depth, 1)) * 10 + 2
                    paragraph.firstLineHeadIndent = qIndent
                    paragraph.headIndent = qIndent
                    paragraph.lineSpacing = 0
                    let isLastLine = (NSMaxRange(parRange) >= NSMaxRange(block.range))
                    paragraph.paragraphSpacing = isLastLine ? 16 : 0
                    paragraph.paragraphSpacingBefore = 0

                case .horizontalRule:
                    // hr: margin 16px 0, height 4px, background #e7e7e7
                    paragraph.paragraphSpacingBefore = 16
                    paragraph.paragraphSpacing = 16

                case .codeBlock:
                    // pre: margin-bottom 16px — only on the LAST line (closing fence).
                    // Internal lines should have tight spacing (code style).
                    paragraph.lineSpacing = 0
                    let isLastLine = (NSMaxRange(parRange) >= NSMaxRange(block.range))
                    paragraph.paragraphSpacing = isLastLine ? 16 : 0
                    paragraph.paragraphSpacingBefore = 0

                case .paragraph:
                    // p: margin-bottom 16px
                    // CSS collapses margins, NSTextView adds them. Use half to compensate.
                    paragraph.paragraphSpacing = 12

                case .empty:
                    // Explicitly set body paragraph style — otherwise empty lines
                    // inherit heading/list paragraph style from the previous character,
                    // causing wrong line height and cursor size.
                    paragraph.paragraphSpacing = 0
                    paragraph.paragraphSpacingBefore = 0

                case .table, .yamlFrontmatter:
                    break
                }

                textStorage.addAttribute(.paragraphStyle, value: paragraph, range: parRange)
            }
        }
    }

    private func isListBlock(_ type: MarkdownBlockType) -> Bool {
        switch type {
        case .unorderedList, .orderedList, .todoItem: return true
        default: return false
        }
    }

    // MARK: - Phase 4: Unified Syntax Hiding

    private func loadImages(textStorage: NSTextStorage, checkRange: NSRange) {
        guard let note = editor?.note else { return }

        var start = checkRange.lowerBound
        var finish = checkRange.upperBound

        if checkRange.upperBound < textStorage.length {
            finish = checkRange.upperBound + 1
        }

        if checkRange.lowerBound > 1 {
            start = checkRange.lowerBound - 1
        }

        let affectedRange = NSRange(start..<finish)
        textStorage.enumerateAttribute(.attachment, in: affectedRange) { (value, range, _) in
            guard let attachment = value as? NSTextAttachment,
                  let meta = textStorage.getMeta(at: range.location) else { return }

            var url = meta.url

            // 1. check data to save (copy/paste, drag/drop)
            if let data = textStorage.getData(at: range.location),
               let result = note.save(data: data, preferredName: meta.url.lastPathComponent) {

                textStorage.addAttributes([
                    .attachmentUrl: result.1,
                    .attachmentPath: result.0
                ], range: range)

                url = result.1
            }

            // 2. load
            let maxWidth = getImageMaxWidth()
            loadImage(attachment: attachment, url: url, range: range, textStorage: textStorage, maxWidth: maxWidth)
        }
    }

    public func loadImage(attachment: NSTextAttachment, url: URL, range: NSRange, textStorage: NSTextStorage, maxWidth: CGFloat) {
        editor?.imagesLoaderQueue.addOperation {
            var image: PlatformImage?
            var size: CGSize?

            if url.isMedia {
                let imageSize = url.getBorderSize(maxWidth: maxWidth)

                size = imageSize
                image = NoteAttachment.getImage(url: url, size: imageSize)
            } else {
                let attachment = NoteAttachment(url: url)
                if let attachmentImage = attachment.getAttachmentImage() {
                    size = attachmentImage.size
                    image = attachmentImage
                }
            }

            DispatchQueue.main.async {
                guard let manager = self.editor?.layoutManager as? NSLayoutManager else { return }

            #if os(iOS)
                attachment.image = image
                if let size = size {
                    attachment.bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
                }

                // iOS only unknown behaviour
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = url.isMedia ? .center : .left
                textStorage.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
            #elseif os(OSX)
                guard let container = self.editor?.textContainer,
                      let attachmentImage = image,
                      let size = size else { return }

                let cell = FSNTextAttachmentCell(textContainer: container, image: attachmentImage)
                cell.image?.size = size
                attachment.image = nil
                attachment.attachmentCell = cell
                attachment.bounds = NSRect(x: 0, y: 0, width: size.width, height: size.height)
            #endif

                let safe = self.safeRange(range, in: textStorage)

                textStorage.edited(.editedAttributes, range: safe, changeInLength: 0)
                manager.invalidateLayout(forCharacterRange: safe, actualCharacterRange: nil)
            }
        }
    }

    #if os(OSX)
    /// Render mermaid/math code blocks as inline images in WYSIWYG mode
    public func renderSpecialCodeBlocks(textStorage: NSTextStorage, codeBlockRanges: [NSRange]) {
        guard NotesTextProcessor.hideSyntax else { return }
        let string = textStorage.string as NSString

        for codeRange in codeBlockRanges {
            guard codeRange.location < string.length, NSMaxRange(codeRange) <= string.length else { continue }

            let firstLineRange = string.lineRange(for: NSRange(location: codeRange.location, length: 0))
            let firstLine = string.substring(with: firstLineRange).trimmingCharacters(in: .whitespacesAndNewlines)

            var blockType: BlockRenderer.BlockType?
            if firstLine.hasPrefix("```mermaid") {
                blockType = .mermaid
            } else if firstLine.hasPrefix("```math") || firstLine.hasPrefix("```latex") {
                blockType = .math
            }
            guard let type = blockType else { continue }

            // Extract the source content (between fences)
            let afterFirstLine = NSMaxRange(firstLineRange)
            let lastCharLoc = max(codeRange.location, NSMaxRange(codeRange) - 1)
            let lastLineRange = string.lineRange(for: NSRange(location: lastCharLoc, length: 0))
            let contentEnd = lastLineRange.location

            guard afterFirstLine < contentEnd else { continue }
            let contentRange = NSRange(location: afterFirstLine, length: contentEnd - afterFirstLine)
            let source = string.substring(with: contentRange).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !source.isEmpty else { continue }

            guard let blockIdx = blocks.firstIndex(where: {
                if case .codeBlock = $0.type { return $0.range == codeRange }
                return false
            }) else {
                continue
            }
            let blockID = blocks[blockIdx].id

            // Skip blocks that are already rendered or already scheduled.
            if blocks[blockIdx].renderMode == .rendered || pendingRenderedBlockIDs.contains(blockID) {
                continue
            }
            pendingRenderedBlockIDs.insert(blockID)

            let maxWidth = getImageMaxWidth()

            // Capture the full original markdown (fences + content) for restoration on click
            let originalMarkdown = string.substring(with: codeRange)

            BlockRenderer.render(source: source, type: type, maxWidth: maxWidth) { [weak self] image in
                guard let self = self else { return }

                DispatchQueue.main.async {
                    defer { self.pendingRenderedBlockIDs.remove(blockID) }
                    guard let image = image else { return }
                    guard let blockIdx = self.blocks.firstIndex(where: { $0.id == blockID }) else { return }
                    guard case .codeBlock = self.blocks[blockIdx].type else { return }

                    let codeRange = self.blocks[blockIdx].range
                    guard codeRange.location < textStorage.length,
                          NSMaxRange(codeRange) <= textStorage.length else { return }

                    // Replace the entire code block with a centered rendered image
                    let scale = min(maxWidth / image.size.width, 1.0)
                    let scaledSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)

                    // Use a cell that spans the full container width and centers the image.
                    // This is stable against paragraph style resets by addTabStops.
                    let attachment = NSTextAttachment()
                    let cell = CenteredImageCell(image: image, imageSize: scaledSize, containerWidth: maxWidth)
                    attachment.attachmentCell = cell
                    // DO NOT set attachment.bounds — it would override the dynamic
                    // cellFrame(for:proposedLineFragment:...) query on the cell,
                    // preventing the image from shrinking when the pane is resized.

                    let attachmentString = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
                    let attRange = NSRange(location: 0, length: attachmentString.length)
                    attachmentString.addAttributes([
                        .renderedBlockSource: source,
                        .renderedBlockType: (type == .mermaid ? RenderedBlockType.mermaid : RenderedBlockType.math).rawValue,
                        .renderedBlockOriginalMarkdown: originalMarkdown
                    ], range: attRange)
                    // Clear code block background so no border appears
                    attachmentString.removeAttribute(.backgroundColor, range: attRange)

                    // Temporarily disable processing to avoid re-highlight cycle
                    self.isRendering = true
                    textStorage.beginEditing()
                    textStorage.replaceCharacters(in: codeRange, with: attachmentString)
                    let replacedRange = NSRange(location: codeRange.location, length: attachmentString.length)
                    // Set flag false BEFORE endEditing so the delegate callback sees it correctly
                    self.isRendering = false
                    textStorage.endEditing()

                    // Re-find the block by ID after endEditing, because endEditing
                    // triggers process() which may rebuild self.blocks, invalidating blockIdx.
                    guard let updatedIdx = self.blocks.firstIndex(where: { $0.id == blockID }) else { return }

                    // Mark the block as rendered (not removed). The block stays in the
                    // model with updated range. codeBlockRanges filters it out so
                    // LayoutManager won't draw a gray background behind the image.
                    // Phase 6 Tier B′ Sub-slice 4: route through
                    // `setRendered` so the canonical offset side-table
                    // reflects this transition; the legacy
                    // `MarkdownBlock.renderMode` field is dual-written
                    // by the mutator.
                    self.blocks[updatedIdx].range = replacedRange
                    self.blocks[updatedIdx].contentRange = replacedRange
                    self.blocks[updatedIdx].syntaxRanges = []
                    self.setRendered(
                        true,
                        storageOffset: replacedRange.location,
                        blockIndex: updatedIdx
                    )
                }
            }
        }
    }

    // Tables are rendered via `TableLayoutFragment` (FSNotesCore) in
    // the WYSIWYG block-model path. The source-mode processor has no
    // table rendering of its own.
    #endif

    private func getImageMaxWidth() -> CGFloat {
        #if os(iOS)
            return UIApplication.getVC().view.frame.width - 35
        #else
            // Prefer the text container width — this is the actual drawable
            // width inside the text view. Using the scroll view's content
            // width overshoots by the text container inset and line fragment
            // padding, causing rendered images to exceed the cellFrame during
            // layout and appear clipped on the left (negative x offset).
            if let container = editor?.textContainer {
                let lfp = container.lineFragmentPadding
                let w = container.size.width - lfp * 2
                if w > 0 { return w }
            }
            if let editorWidth = editor?.enclosingScrollView?.contentView.bounds.width {
                return editorWidth - 40
            }
            // Last-resort fallback — see ImageAttachmentHydrator.containerMaxWidth.
            return 450
        #endif
    }

    private func safeRange(_ range: NSRange, in textStorage: NSTextStorage) -> NSRange {
        let storageLength = textStorage.length
        let loc = min(max(0, range.location), storageLength)
        let end = min(max(0, range.location + range.length), storageLength)
        return NSRange(location: loc, length: end - loc)
    }
}
