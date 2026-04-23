//
//  FeatureFlag.swift
//  FSNotesCore
//
//  Phase 2e-T2-b — Tiny, process-wide feature-flag namespace.
//
//  Flags here gate experimental migration paths that are landed
//  additively (code on disk, unreachable from the default dispatch)
//  and can be toggled ON by tests or, later, by a settings UI once
//  the path is proven. Production code never flips these; the default
//  value is the live, shipped behaviour.
//
//  Why a `static var` and not a full `UserDefaults`-backed setting:
//  (a) 2e-T2-b's sole consumer is the test target exercising the new
//  `TableElement` emission path, and (b) adding persisted settings
//  before the path is green would invite flipping it on by accident in
//  prod. Once 2e-T2-{c,d,e,h} land and the native-cell path is the
//  only code path, this flag goes away.
//

import Foundation

/// Process-wide, test-flippable feature flags gating experimental
/// migration paths.
///
/// All flags default to the shipped/live behaviour. Tests assign the
/// flag to `true` inside `setUp` and restore it in `tearDown`.
public enum FeatureFlag {

    /// Phase 2e-T2-b: enable the native-cell-text table rendering path.
    ///
    /// - When `false` (default, shipping behaviour): `TableTextRenderer`
    ///   emits a single `NSTextAttachment` character (TK1/TK2 widget path
    ///   via `InlineTableView`). The `.string` of the rendered storage
    ///   contains `U+FFFC` at the table's location.
    /// - When `true`: `TableTextRenderer` emits a flat, separator-encoded
    ///   attributed string of the table's cell text — header cells first,
    ///   then body rows, with `U+001F` between cells and `U+001E`
    ///   between rows (see `TableElement.encodeFlatText`). The rendered
    ///   range carries `.blockModelKind = .table`; `BlockModelContentStorageDelegate`
    ///   picks that up and returns a `TableElement`; `BlockModelLayoutManagerDelegate`
    ///   dispatches that to `TableLayoutFragment`. Grid rendering itself
    ///   is still stubbed (lands in 2e-T2-c).
    ///
    /// Flipping this to `true` activates Bug #60 (Find across cells) —
    /// cell text is now part of the `NSTextView`'s searchable string.
    public static var nativeTableElements: Bool = false
}
