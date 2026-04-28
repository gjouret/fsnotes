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
//  Thread model: all wrappers are main-thread only; the flags are
//  non-atomic by design. The editor write path is main-thread only, so
//  there's no contention to protect against. A future background
//  hydration site must marshal its storage mutation back onto the main
//  thread before entering a `performing*` scope — do not make these
//  flags atomic instead.
//
//  Scope roles:
//    • `applyDocumentEditInFlight` — the Phase 3
//      `DocumentEditApplier.applyDocumentEdit` primitive. This is the
//      canonical write path for WYSIWYG edits.
//    • `fillInFlight` — the initial-fill `setAttributedString` paths
//      (`fillViaBlockModel`, `fillViaSourceRenderer`). Whole-document
//      replacement on note switch or reload.
//    • `attachmentHydrationInFlight` — sanctioned permanent exemption
//      for async post-render attachment hydration (display math,
//      mermaid diagrams). The hydrator replaces source text with a
//      rendered-image attachment after `BlockRenderer` finishes the
//      WebView render. This is NOT an editor edit (the `Document`
//      model doesn't change), so it can't route through
//      `applyDocumentEdit`. It also can't be made attribute-only
//      because the source character count differs from the post-
//      hydration U+FFFC character count. Functionally analogous to
//      the IME composition exemption: a documented architectural
//      necessity, not "legacy code waiting to be retired." See
//      ARCHITECTURE.md "Async attachment hydration".
//    • `legacyStorageWriteInFlight` — escape hatch retained for any
//      future bypass-grade write that doesn't yet have a sanctioned
//      scope. Currently has zero production call sites. Tests still
//      reference the flag to verify scope semantics.
//

import Foundation

public enum StorageWriteGuard {
    public private(set) static var applyDocumentEditInFlight = false
    public private(set) static var fillInFlight = false
    public private(set) static var attachmentHydrationInFlight = false
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

    /// Run `body` with `attachmentHydrationInFlight = true`. Sanctioned
    /// permanent exemption for async post-render attachment hydration
    /// (display math, mermaid diagrams) — see the file header for why
    /// this can't route through `applyDocumentEdit`.
    public static func performingAttachmentHydration<T>(_ body: () throws -> T) rethrows -> T {
        let prior = attachmentHydrationInFlight
        attachmentHydrationInFlight = true
        defer { attachmentHydrationInFlight = prior }
        return try body()
    }

    /// Escape hatch retained for any future bypass-grade write that
    /// doesn't yet have a sanctioned scope. Zero production call sites
    /// today. If a new use case appears, prefer adding a dedicated
    /// scope (like `performingAttachmentHydration`) rather than
    /// resurrecting this one — the sanctioned-scope pattern is the
    /// architecturally correct way to authorize a non-canonical write.
    public static func performingLegacyStorageWrite<T>(_ body: () throws -> T) rethrows -> T {
        let prior = legacyStorageWriteInFlight
        legacyStorageWriteInFlight = true
        defer { legacyStorageWriteInFlight = prior }
        return try body()
    }

    /// True when any authorized scope is active.
    public static var isAnyAuthorized: Bool {
        applyDocumentEditInFlight || fillInFlight ||
        attachmentHydrationInFlight || legacyStorageWriteInFlight
    }
}
