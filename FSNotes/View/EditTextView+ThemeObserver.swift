//
//  EditTextView+ThemeObserver.swift
//  FSNotes
//
//  Phase 7.4 — live-apply theme changes to every open editor.
//
//  On `Theme.didChangeNotification`, the editor re-renders its current
//  note via the block-model fill path. `fillViaBlockModel(note:)` lives
//  in `EditTextView+BlockModel.swift` (do-not-touch per the Phase 7.4
//  scope); this file calls it as a public entry point, nothing more.
//
//  Scroll preservation is supplied by `EditorScrollView` (Phase 2f.4)
//  which snapshots + restores the document visible origin around
//  programmatic storage replacements. No extra save/restore needed
//  here; a theme switch re-uses the same code path as a normal fill.
//
//  The observer is attached once per view, in `awakeFromNib` /
//  programmatic init, and torn down in `deinit`. Associated-object
//  storage keeps the token without requiring stored properties on the
//  NSTextView subclass.
//

import Foundation
import AppKit

private var themeObserverKey: UInt8 = 0

extension EditTextView {

    /// Install the Phase 7.4 theme-change observer. Idempotent: a
    /// second call is a no-op.
    ///
    /// Called from `awakeFromNib` (storyboard-loaded editors) and
    /// from the programmatic init used by the test harness. The view
    /// re-renders its current note whenever the active theme changes.
    public func installThemeChangeObserverIfNeeded() {
        if objc_getAssociatedObject(self, &themeObserverKey) != nil {
            return
        }
        let token = NotificationCenter.default.addObserver(
            forName: Theme.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleThemeDidChange()
        }
        objc_setAssociatedObject(
            self, &themeObserverKey, token,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    /// Remove the theme-change observer if one is registered. Paired
    /// with `installThemeChangeObserverIfNeeded`.
    public func removeThemeChangeObserverIfNeeded() {
        guard let token = objc_getAssociatedObject(self, &themeObserverKey) else {
            return
        }
        NotificationCenter.default.removeObserver(token)
        objc_setAssociatedObject(
            self, &themeObserverKey, nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    /// Handler invoked on `Theme.didChangeNotification`. Re-renders
    /// the current note via `fillViaBlockModel(note:)` so every
    /// fragment + element picks up the new `Theme.shared` values on
    /// the next draw. Scroll position is preserved by EditorScrollView.
    private func handleThemeDidChange() {
        guard let note = self.note else { return }
        _ = fillViaBlockModel(note: note)
    }
}
