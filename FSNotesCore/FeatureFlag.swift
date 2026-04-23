//
//  FeatureFlag.swift
//  FSNotesCore
//
//  Tiny, process-wide feature-flag namespace.
//
//  Flags here gate experimental migration paths that are landed
//  additively (code on disk, unreachable from the default dispatch)
//  and can be toggled ON by tests or, later, by a settings UI once
//  the path is proven. Production code never flips these; the default
//  value is the live, shipped behaviour.
//

import Foundation

/// Process-wide, test-flippable feature flags gating experimental
/// migration paths.
///
/// All flags default to the shipped/live behaviour. Tests assign the
/// flag to `true` inside `setUp` and restore it in `tearDown`.
///
/// Phase 4.4 (2026-04-23) deleted `useSourceRendererV2` — source mode
/// now unconditionally uses `SourceRenderer` + `SourceLayoutFragment`.
/// The namespace is retained as the anchor for future flags; remove
/// when the next flag lands.
public enum FeatureFlag {
    // No active flags. Phase 4.4 retired `useSourceRendererV2`.
}
