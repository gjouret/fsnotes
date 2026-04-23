//
//  ThemeAccess.swift
//  FSNotesCore
//
//  Phase 7.2 — nested-group accessors on `BlockStyleTheme` so the
//  rendering pipeline can consume `theme.typography.*`, `theme.spacing.*`,
//  `theme.colors.*`, and `theme.chrome.*` directly from a single `Theme`
//  value. The nested structs themselves live in `ThemeSchema.swift`; this
//  file only wires synthesis + resolution.
//
//  ARCHITECTURAL NOTE
//  ------------------
//  The Phase 7.1 storage model keeps the flat `BlockStyleTheme` (legacy
//  surface consumed by many existing callers) and the nested
//  `ThemeNestedGroups` (new surface used by 7.2+) as two parallel
//  views of the same JSON payload. The nested groups are only populated
//  at load time via `BlockStyleTheme.decodeWithNested(from:)`, but the
//  shared singleton is a flat value. To keep the public renderer API
//  as `theme: Theme = .shared` without modifying `BlockStyleTheme`
//  itself, we expose `theme.typography` / `.spacing` / `.colors` /
//  `.chrome` as computed properties that synthesize a complete nested
//  view from the flat fields on demand.
//
//  Synthesis is cheap (struct copy + a handful of field assignments) and
//  the renderer is not on the hot path for individual render calls
//  (render is invoked once per fill / edit, not per keystroke). A
//  future optimization (7.3 or later) can cache the nested view on the
//  shared theme.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

// MARK: - Nested-group accessors

public extension BlockStyleTheme {

    /// Typography group. Synthesized from the flat fields (and the
    /// compiled-in `ThemeTypography.default` values) so every renderer
    /// caller can write `theme.typography.bodyFontSize` without caring
    /// about the flat-vs-nested split.
    var typography: ThemeTypography {
        var t = ThemeTypography.default
        t.bodyFontName = self.noteFontName
        t.bodyFontSize = self.noteFontSize
        t.codeFontName = self.codeFontName
        t.codeFontSize = self.codeFontSize
        // Phase 7.5.c: promote the bold/italic markers out of the
        // UserDefaults plane into the flat theme surface. Existing
        // callers of `theme.typography.{bold,italic}Marker` continue to
        // read through the synthesis.
        t.italicMarker = self.italic
        t.boldMarker = self.bold
        return t
    }

    /// Spacing group. Synthesized from the flat fields + defaults.
    var spacing: ThemeSpacing {
        var s = ThemeSpacing.default
        s.paragraphSpacing = self.paragraphSpacing
        // Phase 7.5.c: promote `lineHeightMultiple` from the legacy UD
        // key into the flat theme surface. Existing callers of
        // `theme.spacing.lineHeightMultiple` continue to read through
        // this synthesis.
        s.lineHeightMultiple = self.lineHeightMultiple
        // Note: `paragraphSpacingMultiplier` and
        // `structuralBlockSpacingMultiplier` are Phase-7.1 additions that
        // have no flat-field source; they take their `ThemeSpacing.default`
        // values (0.85 and 1.1 respectively), which match the prior
        // hardcoded `DocumentRenderer` constants.
        return s
    }

    /// Colors group. Synthesized from the flat `highlightColor` +
    /// compiled-in defaults for every other field.
    var colors: ThemeColors {
        var c = ThemeColors.default
        // The flat `highlightColor` uses CodableColor (RGBA doubles);
        // the nested form uses ThemeColor (hex / pair / asset). Convert
        // the flat value to a hex string so consumers that read
        // `colors.highlightBackground.resolved(dark:)` see the flat
        // override. If the flat color is the default yellow and the
        // nested default (#FFE600 + alpha 0x80) is what we want, they
        // round-trip within the 0.02-per-component tolerance baked into
        // `colorsApproximatelyEqual`.
        let h = self.highlightColor
        c.highlightBackground = ThemeColor(hex: hexString(from: h))
        return c
    }

    /// Chrome group. Synthesized from the flat blockquote-bar fields +
    /// compiled-in defaults for every other field.
    var chrome: ThemeChrome {
        var ch = ThemeChrome.default
        ch.blockquoteBarWidth = self.blockquoteBarWidth
        ch.blockquoteBarSpacing = self.blockquoteBarSpacing
        ch.blockquoteBarInitialOffset = self.blockquoteBarInitialOffset
        return ch
    }
}

// MARK: - CodableColor → hex

/// Convert a `CodableColor` (RGBA doubles) to an `#RRGGBBAA` hex string
/// so the nested `ThemeColor` surface can carry the same value.
private func hexString(from color: CodableColor) -> String {
    let r = UInt8(clamping: Int((color.red * 255).rounded()))
    let g = UInt8(clamping: Int((color.green * 255).rounded()))
    let b = UInt8(clamping: Int((color.blue * 255).rounded()))
    let a = UInt8(clamping: Int((color.alpha * 255).rounded()))
    return String(format: "#%02X%02X%02X%02X", r, g, b, a)
}

// MARK: - Appearance helper

/// Resolve a `ThemeColor` against the current system appearance.
/// This is the one-liner every renderer / fragment uses when it needs
/// a `PlatformColor` from a theme entry without caring whether the
/// current mode is light or dark.
public extension ThemeColor {

    #if os(OSX)
    /// Resolve against the current effective appearance (macOS).
    /// Uses `NSApp.effectiveAppearance` when available; falls back to
    /// light mode for headless test runs.
    func resolvedForCurrentAppearance(
        fallback: PlatformColor = PlatformColor.black
    ) -> PlatformColor {
        let isDark: Bool
        if let app = NSApplication.shared as NSApplication? {
            let appearance = app.effectiveAppearance
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            isDark = (match == .darkAqua)
        } else {
            isDark = false
        }
        return resolved(dark: isDark, fallback: fallback)
    }
    #else
    func resolvedForCurrentAppearance(
        fallback: PlatformColor = PlatformColor.black
    ) -> PlatformColor {
        return resolved(dark: false, fallback: fallback)
    }
    #endif
}
