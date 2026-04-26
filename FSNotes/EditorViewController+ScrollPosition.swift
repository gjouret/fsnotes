//
//  EditorViewController+ScrollPosition.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 22.12.2025.
//  Copyright © 2025 Oleksandr Hlushchenko. All rights reserved.
//

import Foundation
import AppKit
import STTextKitPlus

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
        // Phase 4.5: TK1 glyph-math restoration removed with the custom
        // layout-manager subclass. Under TK2 we resolve the layout
        // fragment containing the saved character offset and add the
        // saved y-offset within the fragment.
        guard let textView = vcEditor,
              let charIndex = textView.note?.scrollPosition
        else {
            vcEditor?.isScrollPositionSaverLocked = false
            return
        }

        let savedYOffset = textView.note?.scrollOffset ?? 0
        scrollToCharOffsetTK2(charIndex, yOffsetWithinFragment: savedYOffset)

        textView.isScrollPositionSaverLocked = false
    }

    @objc func scrollViewDidScroll(_ notification: Notification) {
        guard notification.object as? NSClipView != nil else { return }

        guard let textView = vcEditor, !textView.isScrollPositionSaverLocked else { return }

        // Phase 4.5: TK1 glyph-math scroll recording removed with the
        // custom layout-manager subclass. TK2 path resolves the fragment
        // at the top of the visible area and records its element's
        // character offset + the sub-fragment y offset.
        if let saved = scrollPositionTK2() {
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

        let charOffset = NSRange(elementRange.location, in: contentStorage).location
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

        guard let textLocation = contentStorage.location(at: charOffset)
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
