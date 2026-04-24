//
//  BlockStyleTheme.swift
//  FSNotesCore
//
//  Centralizes every visual styling constant used by the block-model
//  rendering pipeline. Loaded from a bundled JSON file with optional
//  user overrides from Application Support.
//
//  ARCHITECTURAL CONTRACT:
//  - This struct is the SINGLE SOURCE OF TRUTH for all editor visual
//    styling: fonts, spacing, indent scales, colors, etc.
//  - Renderers receive the theme as a parameter (pure, testable).
//  - App-target drawers read `BlockStyleTheme.shared` (stable singleton).
//  - Settings sliders write to `BlockStyleTheme.shared` and persist via `save()`.
//  - `BlockStyleTheme.default` is the compiled-in failsafe matching all
//    current hardcoded values across the renderer files.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

// MARK: - CodableColor

/// A platform-agnostic color representation that round-trips through JSON.
public struct CodableColor: Codable, Equatable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var platformColor: PlatformColor {
        PlatformColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

// MARK: - BlockStyleTheme

public struct BlockStyleTheme: Codable, Equatable {

    // ── Fonts ────────────────────────────────────────────────────────

    /// Note body font family name. `nil` = system font.
    public var noteFontName: String?

    /// Note body font size in points.
    public var noteFontSize: CGFloat

    /// Code block / inline code font family name.
    public var codeFontName: String

    /// Code block / inline code font size in points.
    public var codeFontSize: CGFloat

    // ── Editor layout ────────────────────────────────────────────────

    /// Inter-line spacing added by the text container.
    public var editorLineSpacing: CGFloat

    /// Maximum line width constraint in points.
    public var lineWidth: CGFloat

    /// Left/right editor margin in points.
    public var marginSize: CGFloat

    // ── Phase 7.5.c flat fields ──────────────────────────────────────
    //
    // These three fields used to live only inside the synthesized nested
    // `ThemeSpacing` / `ThemeTypography` groups. They are promoted to the
    // flat surface so `UserDefaultsManagement` can proxy reads/writes
    // through `Theme.shared` directly. The nested accessors in
    // `ThemeAccess.swift` now synthesize these values from the flat
    // fields so existing callers of `theme.spacing.lineHeightMultiple`
    // etc. keep working.

    /// Line-height multiple used by paragraph styles across the editor.
    /// Legacy default matches `UserDefaultsManagement.lineHeightMultiple`
    /// (1.4) to preserve behaviour for users migrating from pre-7.5.c.
    public var lineHeightMultiple: CGFloat

    /// Italic marker preferred for serialization. `"*"` or `"_"`.
    public var italic: String

    /// Bold marker preferred for serialization. `"**"` or `"__"`.
    public var bold: String

    // ── Heading ──────────────────────────────────────────────────────

    /// Font scale multipliers for H1–H6 (6 elements).
    /// Each heading font = bodyFont.pointSize × scale, rendered bold.
    public var headingFontScales: [CGFloat]

    /// Paragraph spacing BEFORE heading (as multiplier of baseSize).
    /// Suppressed for the first block in a document.
    public var headingSpacingBefore: [CGFloat]

    /// Paragraph spacing AFTER heading (as multiplier of baseSize).
    public var headingSpacingAfter: [CGFloat]

    // ── Paragraph ────────────────────────────────────────────────────

    /// Fixed paragraph spacing in points.
    public var paragraphSpacing: CGFloat

    // ── Code block ───────────────────────────────────────────────────

    public var codeBlockLineSpacing: CGFloat
    public var codeBlockParagraphSpacing: CGFloat
    public var codeBlockSpacingBefore: CGFloat

    // ── List ─────────────────────────────────────────────────────────

    /// Nesting indent as a multiple of bodyFont.pointSize.
    public var listIndentScale: CGFloat

    /// Attachment cell width as a multiple of bodyFont.pointSize.
    public var listCellScale: CGFloat

    /// Bullet diameter as a fraction of bodyFont.capHeight.
    public var listBulletSizeScale: CGFloat

    /// Ordered marker font size as a multiple of bodyFont.pointSize.
    public var listNumberDrawScale: CGFloat

    /// SF Symbol checkbox size as a multiple of bodyFont.pointSize.
    public var listCheckboxDrawScale: CGFloat

    /// Inset for open bullet shapes (stroke width buffer).
    public var listBulletStrokeInset: CGFloat

    /// Line width for open bullet shape strokes.
    public var listBulletStrokeWidth: CGFloat

    /// Paragraph spacing for list blocks.
    public var listBlockSpacing: CGFloat

    // ── Blockquote ───────────────────────────────────────────────────

    /// Initial padding before the first blockquote bar.
    public var blockquoteBarInitialOffset: CGFloat

    /// Spacing between successive blockquote vertical bars.
    public var blockquoteBarSpacing: CGFloat

    /// Width of each blockquote vertical bar.
    public var blockquoteBarWidth: CGFloat

    /// Gap between the last bar and the text.
    public var blockquoteGapAfterBars: CGFloat

    /// Paragraph spacing for blockquote blocks.
    public var blockquoteBlockSpacing: CGFloat

    // ── Table ────────────────────────────────────────────────────────

    /// Placeholder width before table widget resizes.
    public var tablePlaceholderWidth: CGFloat

    /// Placeholder height before table widget resizes.
    public var tablePlaceholderHeight: CGFloat

    /// Paragraph spacing for table blocks.
    public var tableBlockSpacing: CGFloat

    // ── Horizontal rule ──────────────────────────────────────────────

    /// Paragraph spacing for HR blocks.
    public var hrBlockSpacing: CGFloat

    // ── HTML block ───────────────────────────────────────────────────

    public var htmlBlockLineSpacing: CGFloat
    public var htmlBlockParagraphSpacing: CGFloat
    public var htmlBlockSpacingBefore: CGFloat

    // ── Inline ───────────────────────────────────────────────────────

    /// Background color for `==highlight==` text.
    public var highlightColor: CodableColor

    // ── Blank line ───────────────────────────────────────────────────

    /// Near-zero heights for visually collapsing blank-line separators.
    public var blankLineMinHeight: CGFloat
    public var blankLineMaxHeight: CGFloat

    // MARK: - Computed font accessors

    /// Construct the note body font from name + size.
    public var noteFont: PlatformFont {
        if let name = noteFontName, let font = PlatformFont(name: name, size: noteFontSize) {
            return font
        }
        return PlatformFont.systemFont(ofSize: noteFontSize)
    }

    /// Construct the code font from name + size.
    public var codeFont: PlatformFont {
        PlatformFont(name: codeFontName, size: codeFontSize)
            ?? PlatformFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular)
    }

    // MARK: - Safe heading-level access

    /// Heading font scale for a given level (1–6), clamped.
    public func headingFontScale(for level: Int) -> CGFloat {
        let idx = min(max(level - 1, 0), headingFontScales.count - 1)
        return headingFontScales[idx]
    }

    /// Heading spacing-before multiplier for a given level (1–6), clamped.
    public func headingSpacingBeforeMultiplier(for level: Int) -> CGFloat {
        let idx = min(max(level - 1, 0), headingSpacingBefore.count - 1)
        return headingSpacingBefore[idx]
    }

    /// Heading spacing-after multiplier for a given level (1–6), clamped.
    public func headingSpacingAfterMultiplier(for level: Int) -> CGFloat {
        let idx = min(max(level - 1, 0), headingSpacingAfter.count - 1)
        return headingSpacingAfter[idx]
    }

    // MARK: - Blockquote indent

    /// Compute the left indentation needed to clear the vertical bars
    /// drawn by `BlockquoteLayoutFragment` for a given nesting depth.
    /// (Pre-TK2 this was `BlockquoteBorderDrawer`, deleted Batch N+7.)
    public func blockquoteLeftIndent(for level: Int) -> CGFloat {
        guard level > 0 else { return 0 }
        return blockquoteBarInitialOffset
            + CGFloat(level - 1) * blockquoteBarSpacing
            + blockquoteBarWidth
            + blockquoteGapAfterBars
    }

    // MARK: - Memberwise initializer
    //
    // Once we define `init(from decoder:)` and `encode(to:)` below the
    // compiler no longer synthesizes a memberwise init for us. The
    // `BlockStyleTheme.default` factory (and any tests constructing
    // themes by hand) need one, so we declare it explicitly. Argument
    // order matches the struct's field declaration order verbatim.

    public init(
        noteFontName: String?,
        noteFontSize: CGFloat,
        codeFontName: String,
        codeFontSize: CGFloat,
        editorLineSpacing: CGFloat,
        lineWidth: CGFloat,
        marginSize: CGFloat,
        headingFontScales: [CGFloat],
        headingSpacingBefore: [CGFloat],
        headingSpacingAfter: [CGFloat],
        paragraphSpacing: CGFloat,
        codeBlockLineSpacing: CGFloat,
        codeBlockParagraphSpacing: CGFloat,
        codeBlockSpacingBefore: CGFloat,
        listIndentScale: CGFloat,
        listCellScale: CGFloat,
        listBulletSizeScale: CGFloat,
        listNumberDrawScale: CGFloat,
        listCheckboxDrawScale: CGFloat,
        listBulletStrokeInset: CGFloat,
        listBulletStrokeWidth: CGFloat,
        listBlockSpacing: CGFloat,
        blockquoteBarInitialOffset: CGFloat,
        blockquoteBarSpacing: CGFloat,
        blockquoteBarWidth: CGFloat,
        blockquoteGapAfterBars: CGFloat,
        blockquoteBlockSpacing: CGFloat,
        tablePlaceholderWidth: CGFloat,
        tablePlaceholderHeight: CGFloat,
        tableBlockSpacing: CGFloat,
        hrBlockSpacing: CGFloat,
        htmlBlockLineSpacing: CGFloat,
        htmlBlockParagraphSpacing: CGFloat,
        htmlBlockSpacingBefore: CGFloat,
        highlightColor: CodableColor,
        blankLineMinHeight: CGFloat,
        blankLineMaxHeight: CGFloat,
        lineHeightMultiple: CGFloat,
        italic: String,
        bold: String
    ) {
        self.noteFontName = noteFontName
        self.noteFontSize = noteFontSize
        self.codeFontName = codeFontName
        self.codeFontSize = codeFontSize
        self.editorLineSpacing = editorLineSpacing
        self.lineWidth = lineWidth
        self.marginSize = marginSize
        self.lineHeightMultiple = lineHeightMultiple
        self.italic = italic
        self.bold = bold
        self.headingFontScales = headingFontScales
        self.headingSpacingBefore = headingSpacingBefore
        self.headingSpacingAfter = headingSpacingAfter
        self.paragraphSpacing = paragraphSpacing
        self.codeBlockLineSpacing = codeBlockLineSpacing
        self.codeBlockParagraphSpacing = codeBlockParagraphSpacing
        self.codeBlockSpacingBefore = codeBlockSpacingBefore
        self.listIndentScale = listIndentScale
        self.listCellScale = listCellScale
        self.listBulletSizeScale = listBulletSizeScale
        self.listNumberDrawScale = listNumberDrawScale
        self.listCheckboxDrawScale = listCheckboxDrawScale
        self.listBulletStrokeInset = listBulletStrokeInset
        self.listBulletStrokeWidth = listBulletStrokeWidth
        self.listBlockSpacing = listBlockSpacing
        self.blockquoteBarInitialOffset = blockquoteBarInitialOffset
        self.blockquoteBarSpacing = blockquoteBarSpacing
        self.blockquoteBarWidth = blockquoteBarWidth
        self.blockquoteGapAfterBars = blockquoteGapAfterBars
        self.blockquoteBlockSpacing = blockquoteBlockSpacing
        self.tablePlaceholderWidth = tablePlaceholderWidth
        self.tablePlaceholderHeight = tablePlaceholderHeight
        self.tableBlockSpacing = tableBlockSpacing
        self.hrBlockSpacing = hrBlockSpacing
        self.htmlBlockLineSpacing = htmlBlockLineSpacing
        self.htmlBlockParagraphSpacing = htmlBlockParagraphSpacing
        self.htmlBlockSpacingBefore = htmlBlockSpacingBefore
        self.highlightColor = highlightColor
        self.blankLineMinHeight = blankLineMinHeight
        self.blankLineMaxHeight = blankLineMaxHeight
    }

    // MARK: - Codable (tolerant decoder for Phase 7.5.c additions)
    //
    // The three Phase-7.5.c flat fields (`lineHeightMultiple`, `italic`,
    // `bold`) are additive: existing user theme JSON files on disk do
    // NOT contain them. We decode them with `decodeIfPresent(...) ?? .default`
    // so pre-7.5.c themes keep loading cleanly.

    private enum CodingKeys: String, CodingKey {
        case noteFontName, noteFontSize, codeFontName, codeFontSize
        case editorLineSpacing, lineWidth, marginSize
        case lineHeightMultiple, italic, bold
        case headingFontScales, headingSpacingBefore, headingSpacingAfter
        case paragraphSpacing
        case codeBlockLineSpacing, codeBlockParagraphSpacing, codeBlockSpacingBefore
        case listIndentScale, listCellScale, listBulletSizeScale
        case listNumberDrawScale, listCheckboxDrawScale
        case listBulletStrokeInset, listBulletStrokeWidth, listBlockSpacing
        case blockquoteBarInitialOffset, blockquoteBarSpacing, blockquoteBarWidth
        case blockquoteGapAfterBars, blockquoteBlockSpacing
        case tablePlaceholderWidth, tablePlaceholderHeight, tableBlockSpacing
        case hrBlockSpacing
        case htmlBlockLineSpacing, htmlBlockParagraphSpacing, htmlBlockSpacingBefore
        case highlightColor
        case blankLineMinHeight, blankLineMaxHeight
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let def = BlockStyleTheme.default
        self.noteFontName = try c.decodeIfPresent(String.self, forKey: .noteFontName)
        self.noteFontSize = try c.decodeIfPresent(CGFloat.self, forKey: .noteFontSize) ?? def.noteFontSize
        self.codeFontName = try c.decodeIfPresent(String.self, forKey: .codeFontName) ?? def.codeFontName
        self.codeFontSize = try c.decodeIfPresent(CGFloat.self, forKey: .codeFontSize) ?? def.codeFontSize
        self.editorLineSpacing = try c.decodeIfPresent(CGFloat.self, forKey: .editorLineSpacing) ?? def.editorLineSpacing
        self.lineWidth = try c.decodeIfPresent(CGFloat.self, forKey: .lineWidth) ?? def.lineWidth
        self.marginSize = try c.decodeIfPresent(CGFloat.self, forKey: .marginSize) ?? def.marginSize
        // Phase 7.5.c flat fields — tolerate missing for pre-7.5.c themes.
        self.lineHeightMultiple = try c.decodeIfPresent(CGFloat.self, forKey: .lineHeightMultiple) ?? def.lineHeightMultiple
        self.italic = try c.decodeIfPresent(String.self, forKey: .italic) ?? def.italic
        self.bold = try c.decodeIfPresent(String.self, forKey: .bold) ?? def.bold
        self.headingFontScales = try c.decodeIfPresent([CGFloat].self, forKey: .headingFontScales) ?? def.headingFontScales
        self.headingSpacingBefore = try c.decodeIfPresent([CGFloat].self, forKey: .headingSpacingBefore) ?? def.headingSpacingBefore
        self.headingSpacingAfter = try c.decodeIfPresent([CGFloat].self, forKey: .headingSpacingAfter) ?? def.headingSpacingAfter
        self.paragraphSpacing = try c.decodeIfPresent(CGFloat.self, forKey: .paragraphSpacing) ?? def.paragraphSpacing
        self.codeBlockLineSpacing = try c.decodeIfPresent(CGFloat.self, forKey: .codeBlockLineSpacing) ?? def.codeBlockLineSpacing
        self.codeBlockParagraphSpacing = try c.decodeIfPresent(CGFloat.self, forKey: .codeBlockParagraphSpacing) ?? def.codeBlockParagraphSpacing
        self.codeBlockSpacingBefore = try c.decodeIfPresent(CGFloat.self, forKey: .codeBlockSpacingBefore) ?? def.codeBlockSpacingBefore
        self.listIndentScale = try c.decodeIfPresent(CGFloat.self, forKey: .listIndentScale) ?? def.listIndentScale
        self.listCellScale = try c.decodeIfPresent(CGFloat.self, forKey: .listCellScale) ?? def.listCellScale
        self.listBulletSizeScale = try c.decodeIfPresent(CGFloat.self, forKey: .listBulletSizeScale) ?? def.listBulletSizeScale
        self.listNumberDrawScale = try c.decodeIfPresent(CGFloat.self, forKey: .listNumberDrawScale) ?? def.listNumberDrawScale
        self.listCheckboxDrawScale = try c.decodeIfPresent(CGFloat.self, forKey: .listCheckboxDrawScale) ?? def.listCheckboxDrawScale
        self.listBulletStrokeInset = try c.decodeIfPresent(CGFloat.self, forKey: .listBulletStrokeInset) ?? def.listBulletStrokeInset
        self.listBulletStrokeWidth = try c.decodeIfPresent(CGFloat.self, forKey: .listBulletStrokeWidth) ?? def.listBulletStrokeWidth
        self.listBlockSpacing = try c.decodeIfPresent(CGFloat.self, forKey: .listBlockSpacing) ?? def.listBlockSpacing
        self.blockquoteBarInitialOffset = try c.decodeIfPresent(CGFloat.self, forKey: .blockquoteBarInitialOffset) ?? def.blockquoteBarInitialOffset
        self.blockquoteBarSpacing = try c.decodeIfPresent(CGFloat.self, forKey: .blockquoteBarSpacing) ?? def.blockquoteBarSpacing
        self.blockquoteBarWidth = try c.decodeIfPresent(CGFloat.self, forKey: .blockquoteBarWidth) ?? def.blockquoteBarWidth
        self.blockquoteGapAfterBars = try c.decodeIfPresent(CGFloat.self, forKey: .blockquoteGapAfterBars) ?? def.blockquoteGapAfterBars
        self.blockquoteBlockSpacing = try c.decodeIfPresent(CGFloat.self, forKey: .blockquoteBlockSpacing) ?? def.blockquoteBlockSpacing
        self.tablePlaceholderWidth = try c.decodeIfPresent(CGFloat.self, forKey: .tablePlaceholderWidth) ?? def.tablePlaceholderWidth
        self.tablePlaceholderHeight = try c.decodeIfPresent(CGFloat.self, forKey: .tablePlaceholderHeight) ?? def.tablePlaceholderHeight
        self.tableBlockSpacing = try c.decodeIfPresent(CGFloat.self, forKey: .tableBlockSpacing) ?? def.tableBlockSpacing
        self.hrBlockSpacing = try c.decodeIfPresent(CGFloat.self, forKey: .hrBlockSpacing) ?? def.hrBlockSpacing
        self.htmlBlockLineSpacing = try c.decodeIfPresent(CGFloat.self, forKey: .htmlBlockLineSpacing) ?? def.htmlBlockLineSpacing
        self.htmlBlockParagraphSpacing = try c.decodeIfPresent(CGFloat.self, forKey: .htmlBlockParagraphSpacing) ?? def.htmlBlockParagraphSpacing
        self.htmlBlockSpacingBefore = try c.decodeIfPresent(CGFloat.self, forKey: .htmlBlockSpacingBefore) ?? def.htmlBlockSpacingBefore
        self.highlightColor = try c.decodeIfPresent(CodableColor.self, forKey: .highlightColor) ?? def.highlightColor
        self.blankLineMinHeight = try c.decodeIfPresent(CGFloat.self, forKey: .blankLineMinHeight) ?? def.blankLineMinHeight
        self.blankLineMaxHeight = try c.decodeIfPresent(CGFloat.self, forKey: .blankLineMaxHeight) ?? def.blankLineMaxHeight
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(noteFontName, forKey: .noteFontName)
        try c.encode(noteFontSize, forKey: .noteFontSize)
        try c.encode(codeFontName, forKey: .codeFontName)
        try c.encode(codeFontSize, forKey: .codeFontSize)
        try c.encode(editorLineSpacing, forKey: .editorLineSpacing)
        try c.encode(lineWidth, forKey: .lineWidth)
        try c.encode(marginSize, forKey: .marginSize)
        try c.encode(lineHeightMultiple, forKey: .lineHeightMultiple)
        try c.encode(italic, forKey: .italic)
        try c.encode(bold, forKey: .bold)
        try c.encode(headingFontScales, forKey: .headingFontScales)
        try c.encode(headingSpacingBefore, forKey: .headingSpacingBefore)
        try c.encode(headingSpacingAfter, forKey: .headingSpacingAfter)
        try c.encode(paragraphSpacing, forKey: .paragraphSpacing)
        try c.encode(codeBlockLineSpacing, forKey: .codeBlockLineSpacing)
        try c.encode(codeBlockParagraphSpacing, forKey: .codeBlockParagraphSpacing)
        try c.encode(codeBlockSpacingBefore, forKey: .codeBlockSpacingBefore)
        try c.encode(listIndentScale, forKey: .listIndentScale)
        try c.encode(listCellScale, forKey: .listCellScale)
        try c.encode(listBulletSizeScale, forKey: .listBulletSizeScale)
        try c.encode(listNumberDrawScale, forKey: .listNumberDrawScale)
        try c.encode(listCheckboxDrawScale, forKey: .listCheckboxDrawScale)
        try c.encode(listBulletStrokeInset, forKey: .listBulletStrokeInset)
        try c.encode(listBulletStrokeWidth, forKey: .listBulletStrokeWidth)
        try c.encode(listBlockSpacing, forKey: .listBlockSpacing)
        try c.encode(blockquoteBarInitialOffset, forKey: .blockquoteBarInitialOffset)
        try c.encode(blockquoteBarSpacing, forKey: .blockquoteBarSpacing)
        try c.encode(blockquoteBarWidth, forKey: .blockquoteBarWidth)
        try c.encode(blockquoteGapAfterBars, forKey: .blockquoteGapAfterBars)
        try c.encode(blockquoteBlockSpacing, forKey: .blockquoteBlockSpacing)
        try c.encode(tablePlaceholderWidth, forKey: .tablePlaceholderWidth)
        try c.encode(tablePlaceholderHeight, forKey: .tablePlaceholderHeight)
        try c.encode(tableBlockSpacing, forKey: .tableBlockSpacing)
        try c.encode(hrBlockSpacing, forKey: .hrBlockSpacing)
        try c.encode(htmlBlockLineSpacing, forKey: .htmlBlockLineSpacing)
        try c.encode(htmlBlockParagraphSpacing, forKey: .htmlBlockParagraphSpacing)
        try c.encode(htmlBlockSpacingBefore, forKey: .htmlBlockSpacingBefore)
        try c.encode(highlightColor, forKey: .highlightColor)
        try c.encode(blankLineMinHeight, forKey: .blankLineMinHeight)
        try c.encode(blankLineMaxHeight, forKey: .blankLineMaxHeight)
    }
}

// MARK: - Factory default

extension BlockStyleTheme {

    /// Compiled-in factory defaults matching all current hardcoded values
    /// across the renderer files. This is the failsafe when no JSON files
    /// are available.
    public static let `default` = BlockStyleTheme(
        // Fonts
        noteFontName: nil,
        noteFontSize: 14,
        codeFontName: "Source Code Pro",
        codeFontSize: 14,
        // Editor layout
        editorLineSpacing: 4,
        lineWidth: 1000,
        marginSize: 20,
        // Heading
        headingFontScales: [2.0, 1.7, 1.4, 1.2, 1.1, 1.05],
        headingSpacingBefore: [1.2, 1.0, 0.9, 0.8, 0.7, 0.6],
        headingSpacingAfter: [0.67, 0.5, 0.4, 0.35, 0.3, 0.25],
        // Paragraph
        paragraphSpacing: 12,
        // Code block
        codeBlockLineSpacing: 0,
        codeBlockParagraphSpacing: 16,
        codeBlockSpacingBefore: 0,
        // List
        listIndentScale: 1.8,
        listCellScale: 2.0,
        listBulletSizeScale: 0.7,
        listNumberDrawScale: 1.0,
        listCheckboxDrawScale: 1.2,
        listBulletStrokeInset: 0.5,
        listBulletStrokeWidth: 1.0,
        listBlockSpacing: 16,
        // Blockquote
        blockquoteBarInitialOffset: 2,
        blockquoteBarSpacing: 10,
        blockquoteBarWidth: 4,
        blockquoteGapAfterBars: 4,
        blockquoteBlockSpacing: 16,
        // Table
        tablePlaceholderWidth: 400,
        tablePlaceholderHeight: 100,
        tableBlockSpacing: 16,
        // HR
        hrBlockSpacing: 16,
        // HTML block
        htmlBlockLineSpacing: 0,
        htmlBlockParagraphSpacing: 16,
        htmlBlockSpacingBefore: 0,
        // Inline
        highlightColor: CodableColor(red: 1.0, green: 0.9, blue: 0.0, alpha: 0.5),
        // Blank line
        blankLineMinHeight: 0.01,
        blankLineMaxHeight: 0.01,
        // Phase 7.5.c flat fields (see struct definition for rationale)
        lineHeightMultiple: 1.4,
        italic: "*",
        bold: "__"
    )
}

// MARK: - Shared instance + persistence

extension BlockStyleTheme {

    /// Cached production instance. Initialized on first access via `load()`.
    /// Settings sliders mutate this and call `save()` to persist.
    public static var shared: BlockStyleTheme = load()

    /// User theme file location.
    private static var userThemeURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("FSNotes")
        return appSupport.appendingPathComponent("BlockStyleTheme.json")
    }

    /// Load the theme: bundle defaults → user overrides on top.
    /// Returns `.default` if both files are missing or malformed.
    public static func load() -> BlockStyleTheme {
        let decoder = JSONDecoder()

        // Start from compiled-in defaults
        var theme = BlockStyleTheme.default

        // Layer 1: bundled defaults (may customize compiled-in values)
        if let bundleURL = Bundle.main.url(
            forResource: "DefaultBlockStyleTheme", withExtension: "json"
        ), let data = try? Data(contentsOf: bundleURL),
           let bundled = try? decoder.decode(BlockStyleTheme.self, from: data) {
            theme = bundled
        }

        // Layer 2: user overrides
        if let data = try? Data(contentsOf: userThemeURL),
           let user = try? decoder.decode(BlockStyleTheme.self, from: data) {
            theme = user
        }

        return theme
    }

    /// Persist the shared theme to the user theme file.
    public static func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(shared) else { return }

        let dir = userThemeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        try? data.write(to: userThemeURL, options: .atomic)
    }

    /// Re-read from disk and update the shared instance.
    public static func reload() {
        shared = load()
    }

    // `migrateFromUserDefaults()` lived here until Phase 7.5.c. It was
    // deleted because `UserDefaultsManagement.fontSize` etc. now proxy
    // `BlockStyleTheme.shared.noteFontSize` etc. directly — so the old
    // migration body (`shared.noteFontSize = UserDefaultsManagement.fontSize`)
    // became self-referential. The real migration lives at
    // `UserDefaultsManagement.migrateEditorKeysIntoTheme75c(...)`, which
    // reads the raw UD keys once at first launch, seeds `shared`, then
    // removes the backing UD entries so nothing can drift afterward.
}
