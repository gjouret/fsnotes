//
//  TableCellTextView.swift
//  FSNotes
//
//  Phase 8 / Subview Tables — A1 skeleton.
//
//  `NSTextView` subclass that hosts one cell's content. Renders
//  through the standard TK2 pipeline (a normal paragraph), so caret
//  painting, IME, autocorrect, spell-check, undo, copy/paste — all
//  handled by AppKit. The class only adds:
//
//    * Tab / Shift-Tab → focus next/previous cell (via parent)
//    * Up/Down at cell-content top/bottom → exit table (Phase C)
//    * Routing typed-in changes through the document's
//      `EditingOps.replaceTableCellInline` primitive (Phase C)
//
//  A1: skeleton, no editing wiring yet. C1–C7 implement the editing
//  contract on this class.
//

import AppKit

final class TableCellTextView: NSTextView {

    // Phase C will add:
    //   weak var container: TableContainerView?
    //   var cellRow: Int = 0
    //   var cellCol: Int = 0
    //   override func doCommand(by:) — Tab / Shift-Tab / arrow exits
    //   override insertText / shouldChangeText — route through doc
    //
    // Keeping the class shape committed here so phase A's pbxproj
    // wiring lands the file in the build.

}
