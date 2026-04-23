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
public enum FeatureFlag {

    // MARK: - Phase 4.1 anchor: SourceRenderer v2 (do not reorder)

    /// Phase 4.1 (dormant): when true, source mode uses the new
    /// `SourceRenderer` path (Document → marker-preserving attributed
    /// string → `SourceLayoutFragment`) instead of the TK1-shaped
    /// `NotesTextProcessor.highlight` path. Default false until Phase 4.4
    /// flips source mode to the new renderer as its live path.
    public static var useSourceRendererV2: Bool = false
}
