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
        // lookup against `NSTextContentStorage.location(_:offsetBy:)`,
        // plus the y-offset *within* the saved fragment so mid-fragment
        // restores don't snap to the fragment origin.
        guard let textView = vcEditor,
              let charIndex = textView.note?.scrollPosition
        else {
            vcEditor?.isScrollPositionSaverLocked = false
            return
        }

        let savedYOffset = textView.note?.scrollOffset ?? 0

        if let layoutManager = textView.layoutManagerIfTK1,
           let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)

            let glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1),
                                                  in: textContainer)

            // Preserve sub-glyph y-offset so wrapped-paragraph scrolls
            // don't snap to the paragraph's first glyph — parity with the
            // TK2 branch and with the iOS restore path.
            textView.scroll(NSPoint(x: rect.origin.x, y: rect.origin.y + savedYOffset))
        } else {
            // TK2 branch — use the layout fragment containing the saved
            // character offset, plus the saved y-offset within it.
            scrollToCharOffsetTK2(charIndex, yOffsetWithinFragment: savedYOffset)
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
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: glyphRange.location, length: 1),
                in: textContainer
            )

            textView.note?.scrollPosition = charIndex
            // Record how far past the glyph origin the clip top actually
            // sits so restore can reproduce it exactly — mirrors the iOS
            // path (see FSNotes iOS/EditorViewController.swift:1597-1598).
            textView.note?.scrollOffset = visibleRect.origin.y - glyphRect.minY
        } else if let saved = scrollPositionTK2() {
            // Phase 2f.4: TK2 branch — resolve the fragment at the top of
            // the visible area, record its element's character offset and
            // the sub-fragment y offset.
            textView.note?.scrollPosition = saved.charOffset
            textView.note?.scrollOffset = saved.yOffsetWithinFragment
        }
    }

    // MARK: - Phase 2f.4: TK2 scroll position helpers

    /// Snapshot of a TK2 scroll position: the character offset of the
    /// element whose fragment is at the top of the viewport plus the
    /// y-offset of the clip top within that fragment. Stored on the
    /// `Note` as `scrollPosition` + `scrollOffset` so the persisted
    /// contract doesn't change — the tuple is just how the helper
    /// returns both halves together.
    struct TK2ScrollPosition {
        let charOffset: Int
        let yOffsetWithinFragment: CGFloat
    }

    /// Returns the character offset and intra-fragment y-delta for the
    /// layout fragment at the top of the visible viewport. Returns nil
    /// if the editor is not on TK2 or no fragment sits at the clip top.
    func scrollPositionTK2() -> TK2ScrollPosition? {
        guard let textView = vcEditor,
              let tlm = textView.textLayoutManager,
              let contentStorage = tlm.textContentManager as? NSTextContentStorage,
              let clipView = textView.enclosingScrollView?.contentView
        else { return nil }

        let visibleTopY = clipView.bounds.origin.y
        let visibleTop = NSPoint(x: 0, y: visibleTopY)
        guard let fragment = tlm.textLayoutFragment(for: visibleTop),
              let elementRange = fragment.textElement?.elementRange
        else { return nil }

        let docStart = contentStorage.documentRange.location
        let charOffset = contentStorage.offset(from: docStart, to: elementRange.location)
        let yOffset = visibleTopY - fragment.layoutFragmentFrame.origin.y
        return TK2ScrollPosition(charOffset: charOffset, yOffsetWithinFragment: yOffset)
    }

    /// Back-compat shim — callers that only need the char offset (e.g.
    /// the existing unit test) can keep the simpler API. The full
    /// save path uses `scrollPositionTK2()` which also returns the
    /// sub-fragment y-delta.
    func scrollCharOffsetTK2() -> Int? {
        return scrollPositionTK2()?.charOffset
    }

    /// Scrolls the TK2 editor to the layout fragment containing the text
    /// element at `charOffset` characters past the document start, then
    /// adds `yOffsetWithinFragment` so mid-fragment saves restore to the
    /// exact pixel the user was on. Best-effort: if the offset is out of
    /// range or the editor is not on TK2, the call is a no-op.
    func scrollToCharOffsetTK2(_ charOffset: Int, yOffsetWithinFragment: CGFloat = 0) {
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
            let targetY = fragment.layoutFragmentFrame.origin.y + yOffsetWithinFragment
            textView.scroll(NSPoint(x: 0, y: targetY))
            return false
        }
    }
}
