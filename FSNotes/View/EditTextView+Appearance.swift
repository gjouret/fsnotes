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

        // Phase 2a: caret-height tweak uses the TK1 custom layout
        // manager. On TK2 we fall back to the default caret rect.
        if let textStorage = self.textStorage,
           let layoutManager = self.layoutManagerIfTK1 as? LayoutManager {
            let insertionPoint = self.selectedRange().location

            if insertionPoint == textStorage.length, insertionPoint > 0 {
                let lastIndex = insertionPoint - 1
                let attributes = textStorage.attributes(at: lastIndex, effectiveRange: nil)

                let isNewline: Bool = {
                    let ns = textStorage.string as NSString
                    return ns.character(at: lastIndex) == 0x0A
                }()

                let fontToUse: NSFont
                if !isNewline, let font = attributes[.font] as? NSFont {
                    fontToUse = font
                } else {
                    fontToUse = UserDefaultsManagement.noteFont
                }

                newRect.size.height = layoutManager.lineHeight(for: fontToUse)
            }
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

        guard let note = self.note else { return }

        // Block-model path: the renderer will re-highlight from the
        // Document model when refillEditArea re-renders. Skip the
        // source-mode highlight call — it would apply syntax colors to
        // note.content (raw markdown) that the block-model pipeline
        // doesn't use.
        if documentProjection == nil {
            NotesTextProcessor.highlight(attributedString: note.content)
        }

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
        // Phase 2a TK2-safety (2026-04-22): bare `layoutManager` was an
        // implicit `self.layoutManager` read. On a TK2-wired NSTextView
        // that accessor lazy-instantiates a TK1 NSLayoutManager and
        // permanently nils `textLayoutManager`. Route through
        // `layoutManagerIfTK1` so the TK1 invalidation is a no-op
        // under TK2.
        if let storage = textStorage, let lm = layoutManagerIfTK1 {
            let fullRange = NSRange(location: 0, length: storage.length)
            lm.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        }
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
