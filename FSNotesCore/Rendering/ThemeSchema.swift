//
//  ThemeSchema.swift
//  FSNotesCore
//
//  Phase 7.1 — Theme struct + default JSON + loader (additive slice).
//
//  Extends `BlockStyleTheme` (the Phase-2-era seed) with the schema
//  needed by Phase 7.2–7.5. Purely additive: no renderer / fragment
//  wiring yet. Every new field ships with a sensible default that
//  matches the current hardcoded behaviour in DocumentRenderer,
//  InlineRenderer, CodeBlockRenderer, and the Fragments/ directory.
//
//  Dark-mode shape decision: single JSON file with `{"light": "...",
//  "dark": "..."}` value pairs for color fields. A theme bundles "a
//  look" — designers keep both variants in sync and the file travels
//  as one package. Non-color values (sizes, scales) have no variant
//  so they stay scalar. Loader resolves `.light` / `.dark` at read
//  time via the effective appearance.
//
//  Color encoding supports two forms (both decode to the same type):
//    1. Hex string:       "linkColor": "#007AFF"
//       Hex+alpha:         "linkColor": "#007AFFFF"
//    2. Light/dark pair:  "linkColor": {"light": "#007AFF",
//                                        "dark":  "#0A84FF"}
//    3. Asset-catalog:    "linkColor": {"asset": "linkColor"}
//       The loader tries `NSColor(named:)` at resolve time so the
//       system-level appearance switch still works for asset-backed
//       colors (existing pattern for `link` inside the app).
//
//  Validation: `Theme.load(from:)` rejects zero / negative font sizes
//  and corner radii with a user-facing error message. Invalid input
//  logs via `themeLog` and falls back to `BlockStyleTheme.default`
//  (via the existing compiled-in defaults) — never crashes.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

// MARK: - Public modern type alias

/// Modern name for the presentation-layer theme struct. `BlockStyleTheme`
/// is the on-disk name (preserved for backward compatibility with
/// existing callers); `Theme` is the name used in Phase 7.2+ wiring.
public typealias Theme = BlockStyleTheme

// MARK: - Logging shim

/// FSNotesCore-local log helper. Writes to `stderr` so tests see it
/// and app-target `bmLog` callers still route through their own sink.
internal func themeLog(_ message: String) {
    FileHandle.standardError.write(Data(("[Theme] " + message + "\n").utf8))
}

// MARK: - ThemeColor

/// A Codable color that accepts either a hex string, a `{light, dark}`
/// pair, or an asset-catalog lookup name. Use `.resolved(for:)` to
/// turn it into a `PlatformColor` under a given appearance.
public struct ThemeColor: Codable, Equatable {

    /// Hex light-mode value (e.g. `#007AFF` or `#007AFFFF`).
    public var light: String?

    /// Hex dark-mode value; if `nil`, `light` is used in both modes.
    public var dark: String?

    /// Asset-catalog name. When set, `.resolved(for:)` ignores
    /// `light` / `dark` and returns `NSColor(named:)`.
    public var asset: String?

    public init(light: String? = nil, dark: String? = nil, asset: String? = nil) {
        self.light = light
        self.dark = dark
        self.asset = asset
    }

    /// Convenience: a single-value hex color (same in both appearances).
    public init(hex: String) {
        self.light = hex
        self.dark = nil
        self.asset = nil
    }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        // Case 1: bare hex string — "#RRGGBB" or "#RRGGBBAA".
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            self.light = single
            self.dark = nil
            self.asset = nil
            return
        }
        // Case 2: keyed container with light/dark or asset.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.light = try container.decodeIfPresent(String.self, forKey: .light)
        self.dark = try container.decodeIfPresent(String.self, forKey: .dark)
        self.asset = try container.decodeIfPresent(String.self, forKey: .asset)
    }

    public func encode(to encoder: Encoder) throws {
        // Prefer the compact single-string form when only `light` is set
        // and no dark/asset variants are present.
        if let l = light, dark == nil, asset == nil {
            var single = encoder.singleValueContainer()
            try single.encode(l)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(light, forKey: .light)
        try container.encodeIfPresent(dark, forKey: .dark)
        try container.encodeIfPresent(asset, forKey: .asset)
    }

    private enum CodingKeys: String, CodingKey {
        case light, dark, asset
    }

    // MARK: Resolve

    /// Returns the platform color for the current appearance. Falls
    /// back to `fallback` if the hex can't be parsed and no asset is set.
    public func resolved(
        dark isDark: Bool,
        fallback: PlatformColor = PlatformColor.black
    ) -> PlatformColor {
        if let asset = asset, !asset.isEmpty {
            #if os(OSX)
            if let named = PlatformColor(named: asset) {
                return named
            }
            #else
            if let named = PlatformColor(named: asset) {
                return named
            }
            #endif
            // Fall through to hex if asset lookup fails.
        }
        let hex = isDark ? (dark ?? light) : light
        if let hex = hex, let color = ThemeColor.parseHex(hex) {
            return color
        }
        return fallback
    }

    /// Parse a hex color string in the form `#RRGGBB`, `#RRGGBBAA`,
    /// `RRGGBB`, or `RRGGBBAA`. Returns `nil` for malformed input.
    public static func parseHex(_ raw: String) -> PlatformColor? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") {
            s.removeFirst()
        }
        guard s.count == 6 || s.count == 8 else { return nil }
        // Allow only hex digits.
        guard s.allSatisfy({ $0.isHexDigit }) else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 6 {
            r = CGFloat((value & 0xFF0000) >> 16) / 255.0
            g = CGFloat((value & 0x00FF00) >> 8) / 255.0
            b = CGFloat(value & 0x0000FF) / 255.0
            a = 1.0
        } else {
            r = CGFloat((value & 0xFF000000) >> 24) / 255.0
            g = CGFloat((value & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((value & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(value & 0x000000FF) / 255.0
        }
        return PlatformColor(red: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - ThemeTypography

public struct ThemeTypography: Codable, Equatable {
    public var bodyFontName: String?      // nil = system font
    public var bodyFontSize: CGFloat
    public var codeFontName: String
    public var codeFontSize: CGFloat

    /// Heading font sizes absolute (H1...H6) in points.
    /// When `nil`, the renderer applies `headingFontScales` against
    /// `bodyFontSize` (current behaviour). Absolute overrides are for
    /// themes that want fixed sizes.
    public var headingFontSizes: [CGFloat]?

    /// Optional per-heading-level font family override. Array of 6
    /// optional names; `nil` entry = use `bodyFontName`.
    public var headingFontNames: [String?]?

    /// Kbd chip font size as a multiplier of body font size.
    public var kbdFontSizeMultiplier: CGFloat

    /// Subscript / superscript font size as a multiplier of body font.
    public var subSuperFontSizeMultiplier: CGFloat

    /// Inline code font size as a multiplier of body font.
    public var inlineCodeSizeMultiplier: CGFloat

    /// Bold marker style: "**" or "__". Affects serialization only.
    public var boldMarker: String

    /// Italic marker style: "*" or "_". Affects serialization only.
    public var italicMarker: String

    public init(
        bodyFontName: String? = nil,
        bodyFontSize: CGFloat = 14,
        codeFontName: String = "Source Code Pro",
        codeFontSize: CGFloat = 14,
        headingFontSizes: [CGFloat]? = nil,
        headingFontNames: [String?]? = nil,
        kbdFontSizeMultiplier: CGFloat = 0.85,
        subSuperFontSizeMultiplier: CGFloat = 0.75,
        inlineCodeSizeMultiplier: CGFloat = 1.0,
        boldMarker: String = "**",
        italicMarker: String = "*"
    ) {
        self.bodyFontName = bodyFontName
        self.bodyFontSize = bodyFontSize
        self.codeFontName = codeFontName
        self.codeFontSize = codeFontSize
        self.headingFontSizes = headingFontSizes
        self.headingFontNames = headingFontNames
        self.kbdFontSizeMultiplier = kbdFontSizeMultiplier
        self.subSuperFontSizeMultiplier = subSuperFontSizeMultiplier
        self.inlineCodeSizeMultiplier = inlineCodeSizeMultiplier
        self.boldMarker = boldMarker
        self.italicMarker = italicMarker
    }

    public static let `default` = ThemeTypography()
}

// MARK: - ThemeSpacing

public struct ThemeSpacing: Codable, Equatable {
    /// Inter-line multiple applied to paragraph styles.
    public var lineHeightMultiple: CGFloat

    /// Paragraph spacing multiplier (× font size).
    /// Matches `DocumentRenderer.paragraphSpacingMultiplier`.
    public var paragraphSpacingMultiplier: CGFloat

    /// Structural block spacing multiplier (× font size) — used for
    /// code, lists, blockquotes, tables.
    /// Matches `DocumentRenderer.structuralBlockSpacingMultiplier`.
    public var structuralBlockSpacingMultiplier: CGFloat

    /// Fixed paragraph spacing in points (legacy; overrides the
    /// multiplier when > 0). Mirrors `BlockStyleTheme.paragraphSpacing`.
    public var paragraphSpacing: CGFloat

    /// Text container inset (vertical) in points.
    public var textContainerInsetHeight: CGFloat

    /// Text container inset (horizontal) in points.
    public var textContainerInsetWidth: CGFloat

    /// Line fragment padding on the container.
    public var lineFragmentPadding: CGFloat

    public init(
        lineHeightMultiple: CGFloat = 1.0,
        paragraphSpacingMultiplier: CGFloat = 0.85,
        structuralBlockSpacingMultiplier: CGFloat = 1.1,
        paragraphSpacing: CGFloat = 12,
        textContainerInsetHeight: CGFloat = 10,
        textContainerInsetWidth: CGFloat = 0,
        lineFragmentPadding: CGFloat = 10
    ) {
        self.lineHeightMultiple = lineHeightMultiple
        self.paragraphSpacingMultiplier = paragraphSpacingMultiplier
        self.structuralBlockSpacingMultiplier = structuralBlockSpacingMultiplier
        self.paragraphSpacing = paragraphSpacing
        self.textContainerInsetHeight = textContainerInsetHeight
        self.textContainerInsetWidth = textContainerInsetWidth
        self.lineFragmentPadding = lineFragmentPadding
    }

    public static let `default` = ThemeSpacing()
}

// MARK: - ThemeColors

public struct ThemeColors: Codable, Equatable {
    /// Inline link color. Loaded from asset catalog by default to
    /// preserve existing behaviour.
    public var link: ThemeColor

    /// Inline code background.
    public var inlineCodeBackground: ThemeColor

    /// `==highlight==` background — matches existing yellow.
    public var highlightBackground: ThemeColor

    /// Blockquote vertical-bar color.
    public var blockquoteBar: ThemeColor

    /// Code block background fill. When `nil`, the renderer pulls from
    /// the active syntax-highlight theme (existing behaviour).
    public var codeBlockBackground: ThemeColor?

    /// Code block border color.
    public var codeBlockBorder: ThemeColor

    /// Kbd chip fill.
    public var kbdFill: ThemeColor

    /// Kbd chip stroke.
    public var kbdStroke: ThemeColor

    /// Kbd chip bottom-shadow line.
    public var kbdShadow: ThemeColor

    /// Kbd chip foreground text.
    public var kbdForeground: ThemeColor

    /// Horizontal rule stroke.
    public var hrLine: ThemeColor

    /// H1 / H2 heading underline border.
    public var headingBorder: ThemeColor

    public init(
        link: ThemeColor = ThemeColor(asset: "linkColor"),
        inlineCodeBackground: ThemeColor = ThemeColor(
            light: "#F0F0F0F0", dark: "#2C2C2EFF"
        ),
        highlightBackground: ThemeColor = ThemeColor(hex: "#FFE60080"),
        blockquoteBar: ThemeColor = ThemeColor(hex: "#DDDDDD"),
        codeBlockBackground: ThemeColor? = nil,
        codeBlockBorder: ThemeColor = ThemeColor(hex: "#D3D3D3"),
        kbdFill: ThemeColor = ThemeColor(hex: "#FCFCFC"),
        kbdStroke: ThemeColor = ThemeColor(hex: "#CCCCCC"),
        kbdShadow: ThemeColor = ThemeColor(hex: "#BBBBBB"),
        kbdForeground: ThemeColor = ThemeColor(hex: "#555555"),
        hrLine: ThemeColor = ThemeColor(hex: "#E7E7E7"),
        headingBorder: ThemeColor = ThemeColor(hex: "#EEEEEE")
    ) {
        self.link = link
        self.inlineCodeBackground = inlineCodeBackground
        self.highlightBackground = highlightBackground
        self.blockquoteBar = blockquoteBar
        self.codeBlockBackground = codeBlockBackground
        self.codeBlockBorder = codeBlockBorder
        self.kbdFill = kbdFill
        self.kbdStroke = kbdStroke
        self.kbdShadow = kbdShadow
        self.kbdForeground = kbdForeground
        self.hrLine = hrLine
        self.headingBorder = headingBorder
    }

    public static let `default` = ThemeColors()
}

// MARK: - ThemeCodeBlockEditToggle

/// Visual chrome for the hover-triggered `</>` edit-toggle button that
/// sits at the top-right of each code block. Phase 8 Slice 3 addition.
/// Defaults match the hardcoded values the overlay would otherwise use:
/// 5pt corner radius (paired with `CodeBlockLayoutFragment.cornerRadius`),
/// small padding, secondary-label foreground, black translucent fills.
public struct ThemeCodeBlockEditToggle: Codable, Equatable {
    public var cornerRadius: CGFloat
    public var horizontalPadding: CGFloat
    public var verticalPadding: CGFloat
    public var foreground: ThemeColor
    public var backgroundHover: ThemeColor
    public var backgroundActive: ThemeColor

    public init(
        cornerRadius: CGFloat = 5,
        horizontalPadding: CGFloat = 4,
        verticalPadding: CGFloat = 2,
        foreground: ThemeColor = ThemeColor(asset: "secondaryLabel"),
        backgroundHover: ThemeColor = ThemeColor(hex: "#00000014"),
        backgroundActive: ThemeColor = ThemeColor(hex: "#00000028")
    ) {
        self.cornerRadius = cornerRadius
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.foreground = foreground
        self.backgroundHover = backgroundHover
        self.backgroundActive = backgroundActive
    }

    public static let `default` = ThemeCodeBlockEditToggle()
}

// MARK: - ThemeChrome

public struct ThemeChrome: Codable, Equatable {
    /// Kbd chip visual chrome. Matches `KbdBoxParagraphLayoutFragment`.
    public var kbdCornerRadius: CGFloat
    public var kbdBorderWidth: CGFloat
    public var kbdHorizontalPadding: CGFloat
    public var kbdVerticalPaddingTop: CGFloat
    public var kbdVerticalPaddingBottom: CGFloat

    /// Code block. Matches `CodeBlockLayoutFragment`.
    public var codeBlockCornerRadius: CGFloat
    public var codeBlockHorizontalBleed: CGFloat
    public var codeBlockBorderWidth: CGFloat

    /// Blockquote. Matches `BlockquoteLayoutFragment` +
    /// `BlockquoteRenderer` (kept in sync with flat fields on
    /// `BlockStyleTheme` for backward compat).
    public var blockquoteBarWidth: CGFloat
    public var blockquoteBarSpacing: CGFloat
    public var blockquoteBarInitialOffset: CGFloat

    /// Horizontal rule. Matches `HorizontalRuleLayoutFragment`.
    public var hrThickness: CGFloat

    /// Heading border. Matches `HeadingLayoutFragment`.
    public var headingBorderThickness: CGFloat
    public var headingBorderOffsetBelowText: CGFloat

    /// Code-block edit toggle (Phase 8, Slice 3). Visual chrome for the
    /// `</>` hover button drawn by `CodeBlockEditToggleView`. Defaulted
    /// so existing themes that don't set it still load cleanly.
    public var codeBlockEditToggle: ThemeCodeBlockEditToggle

    /// Table hover-handle color (Phase 2e T2-g). Fill used for the
    /// top-gutter column handles and left-gutter row handles drawn by
    /// `TableLayoutFragment` / `TableHandleOverlay`. Defaulted so
    /// existing themes that don't set it still load cleanly.
    public var tableHandle: ThemeColor

    /// Table column drag-resize live-preview line color (Phase 2e
    /// T2-g.4). Default is macOS system-blue. Defaulted so themes
    /// predating T2-g.4 still load cleanly.
    public var tableResizePreview: ThemeColor

    // MARK: - Source-marker color (do not reorder)

    /// Foreground color used by `SourceLayoutFragment` when painting
    /// marker runs (`.markerRange` attribute) of the `SourceRenderer`
    /// path. Default `#999999FF` — a mid gray that reads as "markdown
    /// syntax" without fighting body text. Defaulted so existing themes
    /// that don't set it still load cleanly. Live since Phase 4.4
    /// (source mode now uses `SourceRenderer` + `SourceLayoutFragment`
    /// unconditionally).
    public var sourceMarker: ThemeColor

    public init(
        kbdCornerRadius: CGFloat = 3.0,
        kbdBorderWidth: CGFloat = 1.0,
        kbdHorizontalPadding: CGFloat = 2.0,
        kbdVerticalPaddingTop: CGFloat = 1.0,
        kbdVerticalPaddingBottom: CGFloat = 1.0,
        codeBlockCornerRadius: CGFloat = 5.0,
        codeBlockHorizontalBleed: CGFloat = 5.0,
        codeBlockBorderWidth: CGFloat = 1.0,
        blockquoteBarWidth: CGFloat = 4,
        blockquoteBarSpacing: CGFloat = 10,
        blockquoteBarInitialOffset: CGFloat = 2,
        hrThickness: CGFloat = 4.0,
        headingBorderThickness: CGFloat = 0.5,
        headingBorderOffsetBelowText: CGFloat = 1.0,
        codeBlockEditToggle: ThemeCodeBlockEditToggle = .default,
        tableHandle: ThemeColor = ThemeColor(hex: "#BBBBBBCC"),
        tableResizePreview: ThemeColor = ThemeColor(hex: "#007AFFFF"),
        sourceMarker: ThemeColor = ThemeColor(hex: "#999999FF")
    ) {
        self.kbdCornerRadius = kbdCornerRadius
        self.kbdBorderWidth = kbdBorderWidth
        self.kbdHorizontalPadding = kbdHorizontalPadding
        self.kbdVerticalPaddingTop = kbdVerticalPaddingTop
        self.kbdVerticalPaddingBottom = kbdVerticalPaddingBottom
        self.codeBlockCornerRadius = codeBlockCornerRadius
        self.codeBlockHorizontalBleed = codeBlockHorizontalBleed
        self.codeBlockBorderWidth = codeBlockBorderWidth
        self.blockquoteBarWidth = blockquoteBarWidth
        self.blockquoteBarSpacing = blockquoteBarSpacing
        self.blockquoteBarInitialOffset = blockquoteBarInitialOffset
        self.hrThickness = hrThickness
        self.headingBorderThickness = headingBorderThickness
        self.headingBorderOffsetBelowText = headingBorderOffsetBelowText
        self.codeBlockEditToggle = codeBlockEditToggle
        self.tableHandle = tableHandle
        self.tableResizePreview = tableResizePreview
        self.sourceMarker = sourceMarker
    }

    // MARK: Codable — tolerate missing `codeBlockEditToggle` /
    // `tableHandle` / `sourceMarker` for themes predating the
    // respective slices.

    private enum CodingKeys: String, CodingKey {
        case kbdCornerRadius, kbdBorderWidth,
             kbdHorizontalPadding, kbdVerticalPaddingTop, kbdVerticalPaddingBottom,
             codeBlockCornerRadius, codeBlockHorizontalBleed, codeBlockBorderWidth,
             blockquoteBarWidth, blockquoteBarSpacing, blockquoteBarInitialOffset,
             hrThickness, headingBorderThickness, headingBorderOffsetBelowText,
             codeBlockEditToggle, tableHandle, tableResizePreview,
             sourceMarker
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let def = ThemeChrome.default
        self.kbdCornerRadius = try c.decodeIfPresent(
            CGFloat.self, forKey: .kbdCornerRadius) ?? def.kbdCornerRadius
        self.kbdBorderWidth = try c.decodeIfPresent(
            CGFloat.self, forKey: .kbdBorderWidth) ?? def.kbdBorderWidth
        self.kbdHorizontalPadding = try c.decodeIfPresent(
            CGFloat.self, forKey: .kbdHorizontalPadding) ?? def.kbdHorizontalPadding
        self.kbdVerticalPaddingTop = try c.decodeIfPresent(
            CGFloat.self, forKey: .kbdVerticalPaddingTop) ?? def.kbdVerticalPaddingTop
        self.kbdVerticalPaddingBottom = try c.decodeIfPresent(
            CGFloat.self, forKey: .kbdVerticalPaddingBottom) ?? def.kbdVerticalPaddingBottom
        self.codeBlockCornerRadius = try c.decodeIfPresent(
            CGFloat.self, forKey: .codeBlockCornerRadius) ?? def.codeBlockCornerRadius
        self.codeBlockHorizontalBleed = try c.decodeIfPresent(
            CGFloat.self, forKey: .codeBlockHorizontalBleed) ?? def.codeBlockHorizontalBleed
        self.codeBlockBorderWidth = try c.decodeIfPresent(
            CGFloat.self, forKey: .codeBlockBorderWidth) ?? def.codeBlockBorderWidth
        self.blockquoteBarWidth = try c.decodeIfPresent(
            CGFloat.self, forKey: .blockquoteBarWidth) ?? def.blockquoteBarWidth
        self.blockquoteBarSpacing = try c.decodeIfPresent(
            CGFloat.self, forKey: .blockquoteBarSpacing) ?? def.blockquoteBarSpacing
        self.blockquoteBarInitialOffset = try c.decodeIfPresent(
            CGFloat.self, forKey: .blockquoteBarInitialOffset) ?? def.blockquoteBarInitialOffset
        self.hrThickness = try c.decodeIfPresent(
            CGFloat.self, forKey: .hrThickness) ?? def.hrThickness
        self.headingBorderThickness = try c.decodeIfPresent(
            CGFloat.self, forKey: .headingBorderThickness) ?? def.headingBorderThickness
        self.headingBorderOffsetBelowText = try c.decodeIfPresent(
            CGFloat.self, forKey: .headingBorderOffsetBelowText) ?? def.headingBorderOffsetBelowText
        self.codeBlockEditToggle = try c.decodeIfPresent(
            ThemeCodeBlockEditToggle.self, forKey: .codeBlockEditToggle) ?? def.codeBlockEditToggle
        self.tableHandle = try c.decodeIfPresent(
            ThemeColor.self, forKey: .tableHandle) ?? def.tableHandle
        self.tableResizePreview = try c.decodeIfPresent(
            ThemeColor.self, forKey: .tableResizePreview) ?? def.tableResizePreview
        self.sourceMarker = try c.decodeIfPresent(
            ThemeColor.self, forKey: .sourceMarker) ?? def.sourceMarker
    }

    public static let `default` = ThemeChrome()
}

// MARK: - Extend BlockStyleTheme with nested groups

extension BlockStyleTheme {

    /// Phase 7.1 additive nested groups. Not yet consumed by any
    /// renderer — wired in Phase 7.2–7.3. Accessed via the computed
    /// properties `typography`, `spacing`, `colors`, `chrome` below,
    /// which synthesize values from the flat fields when no nested
    /// block was present in the source JSON.
    ///
    /// These are stored in a side table (keyed by ObjectIdentifier of
    /// the struct type) so they can survive JSON round-trip without
    /// breaking the existing flat Codable surface. At decode time, the
    /// nested blocks are pulled from the JSON's `typography` /
    /// `spacing` / `colors` / `chrome` keys if present, otherwise
    /// synthesized from the flat fields.
    ///
    /// Phase 7.2 migrates all renderers to read through these nested
    /// groups and the flat fields become computed passthroughs.

    // MARK: - Nested group loader/saver

    /// Decode nested groups from a full JSON Data. Returns a tuple so
    /// callers can store both the flat struct and the nested groups
    /// produced from the same payload.
    ///
    /// If the JSON contains no nested-group keys (legacy flat-only
    /// payload), the nested groups are synthesized from the flat
    /// values. If the JSON contains ANY nested key, the full nested
    /// struct must decode cleanly AND validate; a malformed or
    /// out-of-range nested block throws.
    public static func decodeWithNested(
        from data: Data
    ) throws -> (BlockStyleTheme, ThemeNestedGroups) {
        let decoder = JSONDecoder()
        let flat = try decoder.decode(BlockStyleTheme.self, from: data)

        // Detect whether the payload includes any nested-group keys.
        let hasNested = Self.jsonContainsAnyNestedGroup(data)

        let nested: ThemeNestedGroups
        if hasNested {
            // Strict path: decode nested + any decode error propagates.
            // Missing nested blocks are filled in from the flat
            // synthesis so a partial-nested payload still produces a
            // complete `ThemeNestedGroups`.
            let partial: PartialThemeNestedGroups
            do {
                partial = try decoder.decode(
                    PartialThemeNestedGroups.self, from: data
                )
            } catch {
                throw ThemeLoadError.malformed(
                    underlying: error.localizedDescription
                )
            }
            let synth = ThemeNestedGroups.synthesized(from: flat)
            nested = ThemeNestedGroups(
                typography: partial.typography ?? synth.typography,
                spacing: partial.spacing ?? synth.spacing,
                colors: partial.colors ?? synth.colors,
                chrome: partial.chrome ?? synth.chrome
            )
        } else {
            nested = ThemeNestedGroups.synthesized(from: flat)
        }

        try nested.validate()
        return (flat, nested)
    }

    /// Returns `true` when the JSON payload has any of the nested
    /// group keys at the top level.
    private static func jsonContainsAnyNestedGroup(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            return false
        }
        return dict.keys.contains("typography")
            || dict.keys.contains("spacing")
            || dict.keys.contains("colors")
            || dict.keys.contains("chrome")
    }

    /// Encode both flat and nested groups into one JSON payload. The
    /// flat keys are preserved for backward compatibility with the
    /// existing `DefaultBlockStyleTheme.json`; nested keys sit
    /// alongside them and will become the primary source in 7.2.
    public static func encodeWithNested(
        flat: BlockStyleTheme,
        nested: ThemeNestedGroups
    ) throws -> Data {
        let merged = MergedThemePayload(flat: flat, nested: nested)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(merged)
    }
}

// MARK: - ThemeNestedGroups

/// Container for the Phase-7.1 nested Codable groups. This sits
/// alongside the flat `BlockStyleTheme` fields in the on-disk JSON
/// (both encode/decode without collision because the keys differ).
public struct ThemeNestedGroups: Codable, Equatable {
    public var typography: ThemeTypography
    public var spacing: ThemeSpacing
    public var colors: ThemeColors
    public var chrome: ThemeChrome

    public init(
        typography: ThemeTypography = .default,
        spacing: ThemeSpacing = .default,
        colors: ThemeColors = .default,
        chrome: ThemeChrome = .default
    ) {
        self.typography = typography
        self.spacing = spacing
        self.colors = colors
        self.chrome = chrome
    }

    public static let `default` = ThemeNestedGroups()

    /// Synthesize nested groups from the flat `BlockStyleTheme`
    /// values so an older JSON (flat only) still yields a valid
    /// nested view.
    public static func synthesized(
        from flat: BlockStyleTheme
    ) -> ThemeNestedGroups {
        var nested = ThemeNestedGroups.default
        nested.typography.bodyFontName = flat.noteFontName
        nested.typography.bodyFontSize = flat.noteFontSize
        nested.typography.codeFontName = flat.codeFontName
        nested.typography.codeFontSize = flat.codeFontSize
        nested.spacing.paragraphSpacing = flat.paragraphSpacing
        nested.chrome.blockquoteBarWidth = flat.blockquoteBarWidth
        nested.chrome.blockquoteBarSpacing = flat.blockquoteBarSpacing
        nested.chrome.blockquoteBarInitialOffset = flat.blockquoteBarInitialOffset
        return nested
    }

    // MARK: Validation

    /// Validate every numeric range. Throws `ThemeLoadError.invalid`
    /// with a human-readable message on failure.
    public func validate() throws {
        // Font sizes must be strictly positive.
        if typography.bodyFontSize <= 0 {
            throw ThemeLoadError.invalid(
                "typography.bodyFontSize must be > 0 (got \(typography.bodyFontSize))"
            )
        }
        if typography.codeFontSize <= 0 {
            throw ThemeLoadError.invalid(
                "typography.codeFontSize must be > 0 (got \(typography.codeFontSize))"
            )
        }
        if let sizes = typography.headingFontSizes {
            for (i, s) in sizes.enumerated() where s <= 0 {
                throw ThemeLoadError.invalid(
                    "typography.headingFontSizes[\(i)] must be > 0 (got \(s))"
                )
            }
        }
        if typography.kbdFontSizeMultiplier <= 0 {
            throw ThemeLoadError.invalid(
                "typography.kbdFontSizeMultiplier must be > 0"
            )
        }
        if typography.subSuperFontSizeMultiplier <= 0 {
            throw ThemeLoadError.invalid(
                "typography.subSuperFontSizeMultiplier must be > 0"
            )
        }
        if typography.inlineCodeSizeMultiplier <= 0 {
            throw ThemeLoadError.invalid(
                "typography.inlineCodeSizeMultiplier must be > 0"
            )
        }
        // Spacing must be non-negative.
        if spacing.lineHeightMultiple <= 0 {
            throw ThemeLoadError.invalid(
                "spacing.lineHeightMultiple must be > 0"
            )
        }
        if spacing.paragraphSpacing < 0 {
            throw ThemeLoadError.invalid(
                "spacing.paragraphSpacing must be >= 0"
            )
        }
        if spacing.lineFragmentPadding < 0 {
            throw ThemeLoadError.invalid(
                "spacing.lineFragmentPadding must be >= 0"
            )
        }
        // Chrome must be non-negative.
        if chrome.kbdCornerRadius < 0 {
            throw ThemeLoadError.invalid("chrome.kbdCornerRadius must be >= 0")
        }
        if chrome.kbdBorderWidth < 0 {
            throw ThemeLoadError.invalid("chrome.kbdBorderWidth must be >= 0")
        }
        if chrome.codeBlockCornerRadius < 0 {
            throw ThemeLoadError.invalid(
                "chrome.codeBlockCornerRadius must be >= 0"
            )
        }
        if chrome.codeBlockBorderWidth < 0 {
            throw ThemeLoadError.invalid(
                "chrome.codeBlockBorderWidth must be >= 0"
            )
        }
        if chrome.blockquoteBarWidth <= 0 {
            throw ThemeLoadError.invalid(
                "chrome.blockquoteBarWidth must be > 0"
            )
        }
        if chrome.hrThickness <= 0 {
            throw ThemeLoadError.invalid("chrome.hrThickness must be > 0")
        }
        if chrome.headingBorderThickness <= 0 {
            throw ThemeLoadError.invalid(
                "chrome.headingBorderThickness must be > 0"
            )
        }
    }
}

// MARK: - PartialThemeNestedGroups

/// Optional-field mirror of `ThemeNestedGroups`, used during decode
/// so that a payload providing only *some* nested blocks still
/// decodes. The `decodeWithNested` loader fills missing blocks in
/// from the flat-field synthesis before running validation.
fileprivate struct PartialThemeNestedGroups: Codable {
    var typography: ThemeTypography?
    var spacing: ThemeSpacing?
    var colors: ThemeColors?
    var chrome: ThemeChrome?
}

// MARK: - MergedThemePayload

/// Internal container that writes flat + nested groups into a single
/// JSON object. Used by `BlockStyleTheme.encodeWithNested`.
private struct MergedThemePayload: Codable {
    var flat: BlockStyleTheme
    var nested: ThemeNestedGroups

    init(flat: BlockStyleTheme, nested: ThemeNestedGroups) {
        self.flat = flat
        self.nested = nested
    }

    init(from decoder: Decoder) throws {
        self.flat = try BlockStyleTheme(from: decoder)
        self.nested = (try? ThemeNestedGroups(from: decoder))
            ?? ThemeNestedGroups.synthesized(from: self.flat)
    }

    func encode(to encoder: Encoder) throws {
        try flat.encode(to: encoder)
        try nested.encode(to: encoder)
    }
}

// MARK: - ThemeLoadError

/// Errors produced by `BlockStyleTheme.load(from:)`.
public enum ThemeLoadError: Error, CustomStringConvertible, Equatable {
    /// The data could not be decoded into a theme (malformed JSON,
    /// missing required keys, wrong types).
    case malformed(underlying: String)
    /// The theme decoded but contained values outside the valid range.
    case invalid(String)

    public var description: String {
        switch self {
        case .malformed(let u): return "Theme JSON is malformed: \(u)"
        case .invalid(let msg): return "Theme values out of range: \(msg)"
        }
    }
}

// MARK: - Theme loader entry point

extension BlockStyleTheme {

    /// Load a theme from the given URL. Falls back to the bundled
    /// default if the URL is `nil`, the file is missing, malformed, or
    /// fails validation. Logs failures via `themeLog` so users see why
    /// their theme didn't load.
    ///
    /// Returns a tuple of the flat theme + nested groups so callers in
    /// Phase 7.2+ can consume either surface.
    public static func load(
        from url: URL?
    ) -> (theme: BlockStyleTheme, nested: ThemeNestedGroups) {
        guard let url = url else {
            return loadBundledDefault()
        }
        do {
            let data = try Data(contentsOf: url)
            let (theme, nested) = try BlockStyleTheme.decodeWithNested(from: data)
            return (theme, nested)
        } catch let err as ThemeLoadError {
            themeLog("Invalid theme at \(url.path): \(err.description)")
            return loadBundledDefault()
        } catch {
            themeLog("Could not load theme at \(url.path): \(error.localizedDescription)")
            return loadBundledDefault()
        }
    }

    /// Load the bundled default theme. In order of preference:
    /// 1. `default-theme.json` in any loaded bundle
    /// 2. `DefaultBlockStyleTheme.json` (legacy bundled default)
    /// 3. Compiled-in `BlockStyleTheme.default` + synthesized nested
    public static func loadBundledDefault()
        -> (theme: BlockStyleTheme, nested: ThemeNestedGroups) {
        for resource in ["default-theme", "DefaultBlockStyleTheme"] {
            for bundle in Self.candidateBundles() {
                guard let url = bundle.url(
                    forResource: resource, withExtension: "json"
                ) else { continue }
                guard let data = try? Data(contentsOf: url) else { continue }
                if let (theme, nested) = try? Self.decodeWithNested(from: data) {
                    return (theme, nested)
                }
            }
        }
        return (
            BlockStyleTheme.default,
            ThemeNestedGroups.synthesized(from: BlockStyleTheme.default)
        )
    }

    /// Candidate bundles to search. Order matters — the main app
    /// bundle wins over the test bundle so a test theme doesn't leak
    /// into the app binary.
    internal static func candidateBundles() -> [Bundle] {
        var out: [Bundle] = [Bundle.main]
        out.append(Bundle(for: BundleLocator.self))
        return out
    }
}

/// Helper class only used to anchor `Bundle(for:)` inside `FSNotesCore`.
fileprivate final class BundleLocator {}

// MARK: - Theme JSON (de)serialization helpers

extension BlockStyleTheme {

    /// Construct a theme from raw JSON Data. Throws `ThemeLoadError`
    /// on any failure — caller decides whether to fall back.
    public static func theme(
        fromJSON data: Data
    ) throws -> (theme: BlockStyleTheme, nested: ThemeNestedGroups) {
        do {
            return try Self.decodeWithNested(from: data)
        } catch let err as ThemeLoadError {
            throw err
        } catch {
            throw ThemeLoadError.malformed(
                underlying: error.localizedDescription
            )
        }
    }

    /// Serialize the theme + nested groups back to JSON Data.
    public static func toJSON(
        theme: BlockStyleTheme,
        nested: ThemeNestedGroups
    ) throws -> Data {
        try Self.encodeWithNested(flat: theme, nested: nested)
    }
}
