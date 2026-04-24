//
//  CompositionSession.swift
//  FSNotesCore
//
//  Phase 5e — IME / composition buffer.
//
//  The sanctioned architectural exemption to Phase 5a's
//  single-write-path rule. While an input method (Japanese Kotoeri,
//  Simplified Chinese Pinyin, Korean 2-Set, Option-E dead-key accent,
//  emoji picker, etc.) is actively composing a run, AppKit writes
//  directly to `NSTextContentStorage` via `setMarkedText`. We do NOT
//  route those character-by-character marked updates through
//  `DocumentEditApplier.applyDocumentEdit`; instead we record a
//  `CompositionSession` describing the in-flight run and allow the
//  5a DEBUG assertion to bypass mutations that land inside
//  `markedRange` while `isActive == true`.
//
//  On commit (`unmarkText()` or `insertText(_:replacementRange:)`
//  targeting the marked range), the editor builds ONE `EditContract`
//  for the final string via `EditingOps.replace` (or `.delete` for an
//  empty-abort) and routes that through `applyEditResultWithUndo` —
//  the canonical 5a-authorized path. So every composition produces
//  exactly one journaled edit, not N character-level edits.
//
//  Ownership: `CompositionSession` is editor-owned transient state,
//  stored on `EditTextView` via `objc_setAssociatedObject` (matching
//  the existing pattern used for `documentProjection`,
//  `lastEditContract`, `preEditProjection`). It is NOT embedded in
//  `Document` — `Document` is a pure value type whose identity must
//  not carry editor-specific UI state.
//
//  Thread model: main-thread only. AppKit's `NSTextInputClient`
//  protocol is documented main-thread only; the associated-object
//  slot inherits that constraint. There is no shared state here.
//

import Foundation

/// Transient state describing an in-flight input-method composition
/// on a single editor. Not part of `Document` — a value-typed
/// editor-owned snapshot that tracks the marked range and anchor.
///
/// A session is *inactive* by default (`.inactive`); the editor
/// transitions it to active on the first `setMarkedText` call with a
/// non-empty marked string, and back to inactive on `unmarkText()`
/// or a terminal `insertText(_:replacementRange:)` targeting the
/// marked range.
public struct CompositionSession: Equatable {

    /// Block-model cursor captured at the moment composition began.
    /// Survives intervening `applyDocumentEdit` calls because
    /// `DocumentCursor` is storage-index-independent (block-path +
    /// inline-offset). On commit / abort, the editor uses this to
    /// restore a cursor that makes sense even if a queued
    /// `pendingEdits` drain shifted storage indices.
    public var anchorCursor: DocumentCursor

    /// The storage range currently occupied by the marked-but-not-yet-
    /// committed composition. Extends as the user adds characters
    /// (e.g. typing further romaji for Kotoeri); contracts as they
    /// pick a candidate. `length == 0 && isActive == true` is a
    /// transitional state during abort.
    public var markedRange: NSRange

    /// True while composition is in-flight. `false` means "no
    /// composition right now" — the standard typing path applies.
    public var isActive: Bool

    /// External write requests (auto-save, iCloud reload, attachment
    /// hydration, fold re-splice) arriving while `isActive == true`
    /// are deferred here and drained after commit. Reduces the
    /// interaction surface between composition and other storage
    /// writers to: "composition commits atomically; queued work
    /// resumes in FIFO order."
    ///
    /// User keystrokes outside the marked range do *not* land here —
    /// AppKit routes every keystroke through the IME while
    /// composition is active, so by construction the only writes
    /// that show up outside the marked range are non-keystroke
    /// writes from subsystems that don't know composition is
    /// happening.
    public var pendingEdits: [DeferredEdit]

    /// Timestamp of session start. Diagnostic-only — used by the
    /// dogfood logging path to measure composition latency; no
    /// behavioral dependency.
    public var sessionStart: Date

    public init(
        anchorCursor: DocumentCursor,
        markedRange: NSRange,
        isActive: Bool,
        pendingEdits: [DeferredEdit] = [],
        sessionStart: Date = .distantPast
    ) {
        self.anchorCursor = anchorCursor
        self.markedRange = markedRange
        self.isActive = isActive
        self.pendingEdits = pendingEdits
        self.sessionStart = sessionStart
    }

    /// Canonical inactive session. Stored as the default on every
    /// editor; overwritten on composition entry.
    public static let inactive = CompositionSession(
        anchorCursor: DocumentCursor(blockIndex: 0, inlineOffset: 0),
        markedRange: NSRange(location: 0, length: 0),
        isActive: false,
        pendingEdits: [],
        sessionStart: .distantPast
    )
}

/// A write request that arrived while a composition session was
/// active and could not be applied in-flight without violating the
/// marked-range-only storage mutation contract. Drained after
/// commit in FIFO order.
public struct DeferredEdit: Equatable {

    public enum Kind: Equatable {
        /// An external contract (auto-save / theme reload / paste)
        /// routed through `applyEditResultWithUndo`. Replay
        /// re-issues the contract against the post-commit
        /// projection.
        case editContract(actionName: String)
        /// An async attachment hydration (inline math, PDF,
        /// QuickLook). Replay re-runs the hydrator against the
        /// post-commit storage.
        case attachmentHydration(range: NSRange)
        /// A fold re-splice after a user fold toggle. Replay
        /// re-invokes the fold apply pass.
        case foldResplice(range: NSRange)
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }
}

// MARK: - Pure helper: does the marked range cover `editedRange`?

/// Pure predicate used by the 5a DEBUG assertion to decide whether a
/// storage-character edit can be permitted without an authorized
/// `StorageWriteGuard` scope.
///
/// Allowed when:
///   1. A session is active, AND
///   2. The edited range is entirely contained within the marked
///      range (the IME is only rewriting its own in-flight run).
///
/// Not allowed when:
///   - `session.isActive == false` (standard typing should route
///     through `applyDocumentEdit`), OR
///   - `editedRange` extends past `markedRange` in either direction
///     (an unexpected external write during composition — should be
///     deferred via `pendingEdits`, not written through directly).
///
/// This is deliberately a free function, not a method on
/// `CompositionSession`, so it stays pure and trivially testable
/// without an editor.
public func compositionAllowsEdit(
    editedRange: NSRange,
    session: CompositionSession
) -> Bool {
    guard session.isActive else { return false }
    // Contained: edited range's start ≥ marked start AND edited end ≤ marked end.
    let markedStart = session.markedRange.location
    let markedEnd = session.markedRange.location + session.markedRange.length
    let editedStart = editedRange.location
    let editedEnd = editedRange.location + editedRange.length
    return editedStart >= markedStart && editedEnd <= markedEnd
}
