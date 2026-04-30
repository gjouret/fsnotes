//
//  EditTextView+Appearance.swift
//  FSNotes
//
//  Created by Codex on 04.04.2026.
//

import AppKit

extension EditTextView {
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var newRect = rect
        newRect.size.width = caretWidth

        // Phase 4.5: TK1 caret-height tweak (which queried
        // `LayoutManager.lineHeight(for:)`) removed with the custom
        // layout-manager subclass. Under TK2 the default caret rect
        // already tracks the last glyph's font/line height.

        if let outsideRect = caretRectAtSubviewTableBoundary(default: rect) {
            // Subview-tables: when the parent's cursor sits at the
            // U+FFFC of a TableAttachment (start) or one offset past
            // (end), TK2's natural caret rect is the FULL line-fragment
            // height — which equals the entire table's height. That
            // paints a giant caret on top of the table. Clamp to a
            // single-line height so the user sees a normal cursor
            // right next to the table, ready to press Enter for a
            // new paragraph below or Delete to remove the table.
            newRect = outsideRect
            newRect.size.width = caretWidth
        }

        let caretColor = NSColor(red: 0.47, green: 0.53, blue: 0.69, alpha: 1.0)
        super.drawInsertionPoint(in: newRect, color: caretColor, turnedOn: flag)
    }

    /// If the parent's selection is at the start (offset N) or just
    /// past the end (offset N+1) of a TableAttachment's U+FFFC, return
    /// a rect with a normal single-line height so we paint a sensible
    /// caret instead of the line-fragment-height giant.
    ///
    /// Returns nil when the cursor isn't adjacent to a TableAttachment
    /// (the natural-flow rect is correct in that case).
    /// Public entry point for `updateTableCellCaret` to compute a
    /// rect when the cursor is at a subview-tables TableAttachment
    /// boundary. No `default` param — computes from scratch.
    func caretRectAtSubviewTableBoundary() -> NSRect? {
        return caretRectAtSubviewTableBoundary(default: .zero)
    }

    private func caretRectAtSubviewTableBoundary(default rect: NSRect) -> NSRect? {
        guard let storage = textStorage else { return nil }
        let cursor = selectedRange().location
        let len = storage.length

        // Case A: cursor is right after a TableAttachment's U+FFFC —
        // paint a single-line caret at the RIGHT edge of the visible
        // table grid (not at the line fragment's natural end, which
        // with full-width bounds is at the far right margin).
        if cursor > 0, cursor <= len {
            if let attachment = storage.attribute(
                .attachment, at: cursor - 1, effectiveRange: nil
            ) as? TableAttachment {
                return caretRectNextToTable(
                    attachment: attachment,
                    storage: storage,
                    attachmentOffset: cursor - 1,
                    side: .right,
                    fallback: rect
                )
            }
        }
        // Case B: cursor is at a TableAttachment's U+FFFC offset —
        // paint at the LEFT edge of the visible table.
        if cursor < len {
            if let attachment = storage.attribute(
                .attachment, at: cursor, effectiveRange: nil
            ) as? TableAttachment {
                return caretRectNextToTable(
                    attachment: attachment,
                    storage: storage,
                    attachmentOffset: cursor,
                    side: .left,
                    fallback: rect
                )
            }
        }
        return nil
    }

    private enum TableSide { case left, right }

    /// Compute a caret rect on either side of the visible table grid,
    /// at single-line height anchored to the bottom of the table's
    /// vertical extent. Returns nil if TK2 layout state isn't ready.
    private func caretRectNextToTable(
        attachment: TableAttachment,
        storage: NSTextStorage,
        attachmentOffset: Int,
        side: TableSide,
        fallback: NSRect
    ) -> NSRect? {
        // Find the fragment frame for the attachment offset to anchor
        // y. Use TK2's textLayoutManager — it knows where the U+FFFC
        // line fragment lives in container coords.
        guard let tlm = textLayoutManager,
              let cs = tlm.textContentManager as? NSTextContentStorage,
              let loc = cs.location(cs.documentRange.location, offsetBy: attachmentOffset),
              let fragment = tlm.textLayoutFragment(for: loc)
        else { return nil }

        let fragFrame = fragment.layoutFragmentFrame  // container coords
        // X: container coords for left/right edge of visible grid.
        // Computed via the container's `containerWidth` parameter
        // (= text container width) and the attachment's geometry.
        let textContainerWidth = tlm.textContainer?.size.width ?? fragFrame.width
        let visibleWidth = attachment.visibleGridWidth(containerWidth: textContainerWidth)

        let xInContainer: CGFloat
        switch side {
        case .left:  xInContainer = fragFrame.origin.x
        case .right: xInContainer = fragFrame.origin.x + visibleWidth
        }

        // Container → view: add textContainerOrigin.
        let xInView = xInContainer + textContainerOrigin.x

        // Y: bottom-anchor the single-line caret to the table's
        // bottom. Reads as "ready to start a new line below the table".
        let font = UserDefaultsManagement.noteFont
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let yBottomInView = fragFrame.maxY + textContainerOrigin.y
        let yInView = yBottomInView - lineHeight

        return NSRect(
            x: xInView,
            y: yInView,
            width: caretWidth,
            height: lineHeight
        )
    }

    /// Replace the line-fragment-height rect TK2 hands us with a rect
    /// of a single body-font line height, anchored to the BOTTOM of
    /// the original rect. Bottom-anchored matches user expectation —
    /// the caret reads as "ready to start a new line below the table".
    private func clampedToSingleLine(_ rect: NSRect) -> NSRect {
        let font = UserDefaultsManagement.noteFont
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        guard rect.height > lineHeight else { return rect }
        return NSRect(
            x: rect.origin.x,
            y: rect.maxY - lineHeight,
            width: rect.width,
            height: lineHeight
        )
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(true)
    }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        var newInvalidRect = NSRect(origin: invalidRect.origin, size: invalidRect.size)
        newInvalidRect.size.width += self.caretWidth - 1
        super.setNeedsDisplay(newInvalidRect)
    }

    override func toggleContinuousSpellChecking(_ sender: Any?) {
        if let menu = sender as? NSMenuItem {
            UserDefaultsManagement.continuousSpellChecking = (menu.state == .off)
        }
        super.toggleContinuousSpellChecking(sender)
    }

    override func toggleGrammarChecking(_ sender: Any?) {
        if let menu = sender as? NSMenuItem {
            UserDefaultsManagement.grammarChecking = (menu.state == .off)
        }
        super.toggleGrammarChecking(sender)
    }

    override func toggleAutomaticSpellingCorrection(_ sender: Any?) {
        if let menu = sender as? NSMenuItem {
            UserDefaultsManagement.automaticSpellingCorrection = (menu.state == .off)
        }
        super.toggleAutomaticSpellingCorrection(sender)
    }

    override func toggleSmartInsertDelete(_ sender: Any?) {
        if let menu = sender as? NSMenuItem {
            UserDefaultsManagement.smartInsertDelete = (menu.state == .off)
        }
        super.toggleSmartInsertDelete(sender)
    }

    override func toggleAutomaticQuoteSubstitution(_ sender: Any?) {
        if let menu = sender as? NSMenuItem {
            UserDefaultsManagement.automaticQuoteSubstitution = (menu.state == .off)
        }
        super.toggleAutomaticQuoteSubstitution(sender)
    }

    override func toggleAutomaticDataDetection(_ sender: Any?) {
        if let menu = sender as? NSMenuItem {
            UserDefaultsManagement.automaticDataDetection = (menu.state == .off)
        }
        super.toggleAutomaticDataDetection(sender)
    }

    override func toggleAutomaticLinkDetection(_ sender: Any?) {
        if let menu = sender as? NSMenuItem {
            UserDefaultsManagement.automaticLinkDetection = (menu.state == .off)
        }
        super.toggleAutomaticLinkDetection(sender)
    }

    override func toggleAutomaticTextReplacement(_ sender: Any?) {
        if let menu = sender as? NSMenuItem {
            UserDefaultsManagement.automaticTextReplacement = (menu.state == .off)
        }
        super.toggleAutomaticTextReplacement(sender)
    }

    override func toggleAutomaticDashSubstitution(_ sender: Any?) {
        if let menu = sender as? NSMenuItem {
            UserDefaultsManagement.automaticDashSubstitution = (menu.state == .off)
        }
        super.toggleAutomaticDashSubstitution(sender)
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        imagesLoaderQueue.maxConcurrentOperationCount = 3
        imagesLoaderQueue.qualityOfService = .userInteractive

        // Use a semi-transparent selection color so that highlight
        // (yellow background) shows through the selection overlay.
        // The default opaque selection completely obscures highlights.
        selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.6)
        ]

        // Phase 7.4 — observe theme swaps so the editor re-renders
        // with the new Theme.shared without needing an app restart.
        installThemeChangeObserverIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() {
        UserDataService.instance.isDark = effectiveAppearance.isDark
        storage.resetCacheAttributes()

        let webkitPreview = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wkPreview")
        try? FileManager.default.removeItem(at: webkitPreview)

        NotesTextProcessor.hl = nil

        guard let _ = self.note else { return }

        // Both WYSIWYG (block-model) and source-mode (SourceRenderer)
        // re-render from the Document via `refillEditArea(force: true)`
        // below.
        viewDelegate?.refillEditArea(force: true)
    }

    public func updateTextContainerInset() {
        textContainerInset.width = getInsetWidth()
    }

    /// Called when the editor's available width changes (window resize,
    /// split-view divider drag). Invalidates layout so width-sensitive
    /// fragments (e.g. `CenteredImageCell` mermaid/math scaling) rebuild.
    /// Table attachments re-layout themselves on the next TK2 pass when
    /// the container width changes.
    public func reflowAttachmentsForWidthChange() {
        // Phase 4.5 moved this off the deleted TK1 NSLayoutManager
        // subclass. Under TK2, width-sensitive fragments
        // (`CenteredImageCell`, table attachments, the mermaid/math
        // bitmap fragments) cache measured geometry on first layout;
        // without an explicit invalidation, a window / split-view
        // resize leaves stale geometry until the user scrolls or
        // edits. Invalidate the whole document range — cheap on TK2,
        // defensive against any fragment that caches more than it
        // should.
        if let tlm = textLayoutManager, let tcm = tlm.textContentManager {
            tlm.invalidateLayout(for: tcm.documentRange)
        }
        needsDisplay = true
    }

    public func getInsetWidth() -> CGFloat {
        let lineWidth = UserDefaultsManagement.lineWidth
        let margin = UserDefaultsManagement.marginSize
        let width = frame.width
        let gutter: Float = NotesTextProcessor.hideSyntax ? Float(EditTextView.gutterWidth) : 0

        if lineWidth == 1000 {
            return CGFloat(margin + gutter)
        }

        guard Float(width) - margin * 2 > lineWidth else {
            return CGFloat(margin + gutter)
        }

        return CGFloat((Float(width) - lineWidth) / 2 + gutter)
    }
}
