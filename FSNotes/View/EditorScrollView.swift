//
//  EditorScrollView.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 10/7/18.
//  Copyright © 2018 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa

class EditorScrollView: NSScrollView {
    private var initialHeight: CGFloat?

    override var isFindBarVisible: Bool {
        set {
            if let clip = self.subviews.first as? NSClipView {
                if newValue {
                    clip.contentInsets.top = 60
                    if let documentView = self.documentView {
                        documentView.scroll(NSPoint(x: 0, y: -60))
                    }
                } else {
                    clip.contentInsets.top = 10
                    // Restore scroll position so the note doesn't retain
                    // the extra whitespace from the find bar offset.
                    if let documentView = self.documentView {
                        let currentOrigin = documentView.visibleRect.origin
                        let restored = NSPoint(x: currentOrigin.x, y: max(0, currentOrigin.y))
                        documentView.scroll(restored)
                    }
                }
            }

            super.isFindBarVisible = newValue
        }
        get {
            return super.isFindBarVisible
        }
    }
//
//
//    override func findBarViewDidChangeHeight() {
//       if #available(OSX 10.14, *) {
//            guard let currentHeight = findBarView?.frame.height else { return }
//
//            guard let initialHeight = self.initialHeight else {
//                self.initialHeight = currentHeight
//                return
//            }
//
//            if let clip = self.subviews.first as? NSClipView {
//                let margin = currentHeight > initialHeight ? 65 : 40
//                clip.contentInsets.top = CGFloat(margin)
//
//                if let documentView = self.documentView {
//                    documentView.scroll(NSPoint(x: 0, y: -margin))
//                }
//            }
//        } else {
//            super.findBarViewDidChangeHeight()
//        }
//    }
}
