//
//  EditorSplitView.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 4/20/18.
//  Copyright © 2018 Oleksandr Glushchenko. All rights reserved.
//

import Cocoa

class EditorSplitView: NSSplitView, NSSplitViewDelegate {
    public var shouldHideDivider = false

    override func draw(_ dirtyRect: NSRect) {
        self.delegate = self
        super.draw(dirtyRect)
    }

    override func minPossiblePositionOfDivider(at dividerIndex: Int) -> CGFloat {
        return 0
    }

    /*
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {

        return (shouldHideDivider || UserDefaultsManagement.horizontalOrientation) ? 0 : 200
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {

        return UserDefaultsManagement.horizontalOrientation ? 99999 : 350
    }*/

    override var dividerColor: NSColor {
        return NSColor.init(named: "divider")!
    }

    override var dividerThickness: CGFloat {
        get {
            return shouldHideDivider ? 0 : 1
        }
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Persist the notes-list (left subview) width whenever it's at a
        // sensible size so we can restore it if window auto-resize later
        // collapses it to 0. We only save "good" widths — 0 or near-zero
        // means the pane is collapsed (by toggle or auto-collapse) and we
        // want to preserve the last-known-good value instead.
        //
        // Skip during a window live-resize: those intermediate widths are
        // a proportional cascade from the window edge, not the user's
        // intent. MainWindowController snapshots pre-resize widths and
        // restores from the snapshot when the window grows back.
        let inWindowLiveResize = window?.inLiveResize ?? false
        if !inWindowLiveResize, let first = subviews.first {
            let w = first.frame.width
            if w > 50 {
                UserDefaultsManagement.notesListWidth = w
            }
        }
        ViewController.shared()?.viewDidResize()
        ViewController.shared()?.editor?.reflowAttachmentsForWidthChange()
    }
    
    func splitViewWillResizeSubviews(_ notification: Notification) {
        if let vc = ViewController.shared() {
            vc.editor.updateTextContainerInset()
        }
    }

}
