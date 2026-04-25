//
//  InlineAttachmentOpenPolicy.swift
//  FSNotes
//
//  Pure decision policy for "should this click open the underlying
//  attachment in its default macOS app." Bug #23: double-clicking on
//  an inline PDF / QuickLook preview should perform the macOS Open
//  action (Preview for PDFs, Numbers for `.numbers`, etc.).
//
//  The live trigger is an `NSClickGestureRecognizer(numberOfClicksRequired:
//  2)` attached to `InlinePDFView` and `InlineQuickLookView`. The
//  predicate here lets unit tests pin the decision logic without
//  needing a real `NSEvent` synthesis path.
//

import Foundation

/// Pure helpers governing when an inline attachment view should open
/// its file in the user's default app. Stateless namespace.
enum InlineAttachmentOpenPolicy {

    /// Returns `true` when a click event with `clickCount` clicks
    /// should trigger the "open in native app" action. macOS reports
    /// `clickCount == 2` for a double-click; single, triple, and
    /// higher click counts are ignored so users can still interact
    /// with the embedded preview (single-click selection in PDFKit,
    /// triple-click paragraph selection in QuickLook text previews,
    /// etc.) without accidentally launching the host application.
    static func shouldOpenOnDoubleClick(clickCount: Int) -> Bool {
        return clickCount == 2
    }
}
