//
//  EditorViewController+ScrollPosition.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 22.12.2025.
//  Copyright © 2025 Oleksandr Hlushchenko. All rights reserved.
//

import Foundation
import AppKit

extension EditorViewController {
    
    func initScrollObserver() {
        if let textView = vcEditor, let scrollView = textView.enclosingScrollView {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollViewDidScroll),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            
            scrollView.contentView.postsBoundsChangedNotifications = true
        }
    }
    
    func restoreScrollPosition() {
        // Phase 2a: TK1-only scroll-position restoration via glyph math.
        // Phase 2f.4: TK2 restoration via `NSTextLayoutFragment` frame
        // lookup against `NSTextContentStorage.location(_:offsetBy:)`.
        guard let textView = vcEditor,
              let charIndex = textView.note?.scrollPosition
        else {
            vcEditor?.isScrollPositionSaverLocked = false
            return
        }

        if let layoutManager = textView.layoutManagerIfTK1,
           let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)

            let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1),
                                                  in: textContainer)

            textView.scroll(rect.origin)
        } else {
            // TK2 branch — use the layout fragment containing the saved
            // character offset.
            scrollToCharOffsetTK2(charIndex)
        }

        textView.isScrollPositionSaverLocked = false
    }

    @objc func scrollViewDidScroll(_ notification: Notification) {
        guard notification.object as? NSClipView != nil else { return }

        guard let textView = vcEditor, !textView.isScrollPositionSaverLocked else { return }

        if let layoutManager = textView.layoutManagerIfTK1,
           let textContainer = textView.textContainer {
            // Phase 2a: TK1 glyph math.
            let visibleRect = textView.enclosingScrollView!.contentView.bounds
            let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect,
                                                       in: textContainer)

            textView.note?.scrollPosition = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        } else if let charOffset = scrollCharOffsetTK2() {
            // Phase 2f.4: TK2 branch — resolve the fragment at the top of
            // the visible area and record its element's character offset.
            textView.note?.scrollPosition = charOffset
        }
    }

    // MARK: - Phase 2f.4: TK2 scroll position helpers

    /// Returns the character offset (from document start) of the text
    /// element whose fragment is at the top of the visible viewport.
    /// Returns nil if the editor is not on TK2 or the viewport is empty.
    func scrollCharOffsetTK2() -> Int? {
        guard let textView = vcEditor,
              let tlm = textView.textLayoutManager,
              let contentStorage = tlm.textContentManager as? NSTextContentStorage,
              let clipView = textView.enclosingScrollView?.contentView
        else { return nil }

        let visibleTop = NSPoint(x: 0, y: clipView.bounds.origin.y)
        guard let fragment = tlm.textLayoutFragment(for: visibleTop),
              let elementRange = fragment.textElement?.elementRange
        else { return nil }

        let docStart = contentStorage.documentRange.location
        return contentStorage.offset(from: docStart, to: elementRange.location)
    }

    /// Scrolls the TK2 editor to the layout fragment containing the text
    /// element at `charOffset` characters past the document start.
    /// Best-effort: if the offset is out of range or the editor is not on
    /// TK2, the call is a no-op.
    func scrollToCharOffsetTK2(_ charOffset: Int) {
        guard let textView = vcEditor,
              let tlm = textView.textLayoutManager,
              let contentStorage = tlm.textContentManager as? NSTextContentStorage
        else { return }

        let docStart = contentStorage.documentRange.location
        guard let textLocation = contentStorage.location(docStart, offsetBy: charOffset)
        else { return }

        // Ensure layout has been realized around the target location before
        // asking for the fragment frame — the viewport layout controller is
        // lazy and may not have laid out fragments below the visible area.
        tlm.ensureLayout(for: NSTextRange(location: textLocation))

        tlm.enumerateTextLayoutFragments(from: textLocation, options: []) { fragment in
            textView.scroll(NSPoint(x: 0, y: fragment.layoutFragmentFrame.origin.y))
            return false
        }
    }
}
