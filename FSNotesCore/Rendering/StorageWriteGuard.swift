//
//  StorageWriteGuard.swift
//  FSNotesCore
//
//  Phase 5a — single-write-path enforcement for NSTextContentStorage.
//
//  Every character-replacement mutation of the editor's content storage
//  must happen inside exactly one authorized scope. `StorageWriteGuard`
//  is the scope marker: each of the three `performing*` helpers sets a
//  flag for the duration of its body and clears it on return (via
//  `defer`). The debug assertion in
//  `TextStorageProcessor.didProcessEditing` reads `isAnyAuthorized` and
//  traps if a WYSIWYG-mode character change happened with no
//  authorization active.
//
//  Release builds compile to no-ops in the sense that nothing reads the
//  flags — the storage is only set/cleared around writes, no production
//  codepath branches on their value. The assertion is gated on
//  `#if DEBUG` and never fires in Release.
//
//  Scope roles:
//    • `applyDocumentEditInFlight` — the Phase 3
//      `DocumentEditApplier.applyDocumentEdit` primitive. This is the
//      canonical write path for WYSIWYG edits.
//    • `fillInFlight` — the initial-fill `setAttributedString` paths
//      (`fillViaBlockModel`, `fillViaSourceRenderer`). Whole-document
//      replacement on note switch or reload.
//    • `legacyStorageWriteInFlight` — escape hatch for call sites that
//      haven't yet been routed through `applyDocumentEdit` (fold
//      re-splice, restore-from-undo, async attachment hydration
//      post-render). Each wrapper should carry a TODO comment
//      explaining why the call site can't route cleanly and what
//      would be needed to retire the escape hatch.
//

import Foundation

public enum StorageWriteGuard {
    public private(set) static var applyDocumentEditInFlight = false
    public private(set) static var fillInFlight = false
    public private(set) static var legacyStorageWriteInFlight = false

    /// Run `body` with `applyDocumentEditInFlight = true`. Called from
    /// `DocumentEditApplier.applyDocumentEdit` wrapping its mutation.
    public static func performingApplyDocumentEdit<T>(_ body: () throws -> T) rethrows -> T {
        let prior = applyDocumentEditInFlight
        applyDocumentEditInFlight = true
        defer { applyDocumentEditInFlight = prior }
        return try body()
    }

    /// Run `body` with `fillInFlight = true`. Called from fill paths
    /// (`fillViaBlockModel`, `fillViaSourceRenderer`) that do a full
    /// `setAttributedString` on initial note load.
    public static func performingFill<T>(_ body: () throws -> T) rethrows -> T {
        let prior = fillInFlight
        fillInFlight = true
        defer { fillInFlight = prior }
        return try body()
    }

    /// Escape hatch for call sites that haven't yet been routed through
    /// `applyDocumentEdit` (fold re-splice, restore-from-undo, async
    /// attachment hydration post-render). Each wrapper should carry a
    /// TODO comment explaining why the call site can't route cleanly
    /// and what would be needed to retire the escape hatch.
    public static func performingLegacyStorageWrite<T>(_ body: () throws -> T) rethrows -> T {
        let prior = legacyStorageWriteInFlight
        legacyStorageWriteInFlight = true
        defer { legacyStorageWriteInFlight = prior }
        return try body()
    }

    /// True when any authorized scope is active.
    public static var isAnyAuthorized: Bool {
        applyDocumentEditInFlight || fillInFlight || legacyStorageWriteInFlight
    }
}
