//
//  EditTextView+Appearance.swift
//  FSNotes
//
//  Created by Codex on 04.04.2026.
//

import AppKit

extension EditTextView {
    /// Phase 11 Slice B fix: when the cursor is inside a TableElement,
    /// TK2's default `rect` argument is computed from the fragment's
    /// natural-flow `textLineFragments`, which `TableLayoutFragment.draw`
    /// does not honor (cells are painted at custom grid positions). The
    /// caret therefore appears at the top-left of the fragment — in
    /// the column-handle strip — instead of inside the cell the
    /// cursor's storage offset addresses. We compute the geometrically
    /// correct rect via `TableLayoutFragment.caretRectInCell(...)` and
    /// hand it to super in place of the natural-flow rect.
    public func caretRectIfInTableCell() -> NSRect? {
        guard let tlm = self.textLayoutManager,
              let contentStorage = tlm.textContentManager
                as? NSTextContentStorage
        else { return nil }
        let cursor = selectedRange().location
        guard cursor >= 0,
              cursor <= (textStorage?.length ?? 0)
        else { return nil }
        let docStart = contentStorage.documentRange.location
        guard let cursorLoc = contentStorage.location(
            docStart, offsetBy: cursor
        ) else { return nil }
        guard let fragment = tlm.textLayoutFragment(for: cursorLoc),
              let tableFrag = fragment as? TableLayoutFragment,
              let element = fragment.textElement as? TableElement,
              let elementRange = element.elementRange
        else { return nil }
        // Force TK2 to finalize layout-fragment stacking before we
        // read `fragment.layoutFragmentFrame.origin.y`. Without this,
        // a query immediately after `Insert Table` (or any path that
        // splices a new fragment into the document) returns an
        // *estimated* origin — the layout manager hasn't yet settled
        // the table fragment's vertical position relative to preceding
        // fragments. The next caret query (after typing one char,
        // which forces a real layout pass) returns the *settled*
        // origin, ~16pt up the page. The user perceives this as the
        // caret jumping up after typing the first character.
        // `ensureLayout(for:)` is documented to drive a synchronous
        // layout pass for the given range, so the next read returns
        // the authoritative origin.
        tlm.ensureLayout(for: elementRange)
        let elementStart = contentStorage.offset(
            from: docStart, to: elementRange.location
        )
        let localOffset = cursor - elementStart
        // Cursor-aware: a click-to-cell parks the caret at the END
        // of the cell's content, which is on the following U+001F /
        // U+001E separator for non-last cells. The strict locator
        // returns nil for separator offsets; `cellAtCursor` resolves
        // to the preceding cell. Without this, the caret falls back
        // to TK2's natural-flow rect after every click and lands in
        // the column-handle strip.
        guard let (row, col) = element.cellAtCursor(
            forOffset: localOffset
        ) else { return nil }
        guard let cellStart = element.offset(
            forCellAt: (row: row, col: col)
        ) else { return nil }
        let offsetInCell = max(0, localOffset - cellStart)
        guard let localRect = tableFrag.caretRectInCell(
            row: row, col: col,
            cellLocalOffset: offsetInCell,
            caretWidth: caretWidth
        ) else { return nil }
        // Convert fragment-local coords → text-view (NSView) coords.
        // Pipeline: fragment-local + fragment.origin = container coords;
        // container coords + textContainerOrigin = view coords. The
        // earlier code stopped at container coords, so the caret was
        // painted offset by the textContainerOrigin (which carries the
        // EditTextView -7pt y override + the system-default x/y inset)
        // — visible to the user as the caret appearing above-left of
        // the cell rather than inside it.
        let frameOrigin = fragment.layoutFragmentFrame.origin
        let containerOrigin = textContainerOrigin
        return NSRect(
            x: localRect.origin.x + frameOrigin.x + containerOrigin.x,
            y: localRect.origin.y + frameOrigin.y + containerOrigin.y,
            width: localRect.width,
            height: localRect.height
        )
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var newRect = rect
        newRect.size.width = caretWidth

        // Phase 4.5: TK1 caret-height tweak (which queried
        // `LayoutManager.lineHeight(for:)`) removed with the custom
        // layout-manager subclass. Under TK2 the default caret rect
        // already tracks the last glyph's font/line height.

        // Phase 11 Slice B: when the cursor is inside a TableElement,
        // override the natural-flow `rect` with the geometrically
        // correct in-cell caret rect. See `caretRectIfInTableCell`
        // for why TK2's default is wrong in this case.
        if let tableRect = caretRectIfInTableCell() {
            bmLog("✏️ drawInsertionPoint: TK2-rect=\(rect) tableRect=\(tableRect) containerOrigin=\(textContainerOrigin) selRange=\(selectedRange())")
            newRect = tableRect
            newRect.size.width = caretWidth
        }

        let caretColor = NSColor(red: 0.47, green: 0.53, blue: 0.69, alpha: 1.0)
        super.drawInsertionPoint(in: newRect, color: caretColor, turnedOn: flag)
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
    /// Native tables re-layout themselves on the next TK2 pass when the
    /// container width changes — `TableLayoutFragment` re-computes
    /// column widths on each layout.
    public func reflowAttachmentsForWidthChange() {
        // Phase 4.5 moved this off the deleted TK1 NSLayoutManager
        // subclass. Under TK2, width-sensitive fragments
        // (`CenteredImageCell`, `TableLayoutFragment`, the mermaid/math
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
