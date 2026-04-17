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

    /// Embedded image display width in points.
    public var imagesWidth: CGFloat

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
    /// drawn by BlockquoteBorderDrawer for a given nesting depth.
    public func blockquoteLeftIndent(for level: Int) -> CGFloat {
        guard level > 0 else { return 0 }
        return blockquoteBarInitialOffset
            + CGFloat(level - 1) * blockquoteBarSpacing
            + blockquoteBarWidth
            + blockquoteGapAfterBars
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
        imagesWidth: 450,
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
        blankLineMaxHeight: 0.01
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

    /// One-time migration from UserDefaults slider values.
    /// Call on app launch; writes current UserDefaults values into the
    /// shared theme and persists. No-op if already migrated.
    public static func migrateFromUserDefaults() {
        let key = "blockStyleThemeV1Migrated"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        // Read current UserDefaults values
        shared.noteFontSize = CGFloat(UserDefaultsManagement.fontSize)
        shared.codeFontSize = CGFloat(UserDefaultsManagement.codeFontSize)
        shared.codeFontName = UserDefaultsManagement.codeFontName
        shared.editorLineSpacing = CGFloat(UserDefaultsManagement.editorLineSpacing)
        shared.lineWidth = CGFloat(UserDefaultsManagement.lineWidth)
        shared.marginSize = CGFloat(UserDefaultsManagement.marginSize)
        shared.imagesWidth = CGFloat(UserDefaultsManagement.imagesWidth)

        // Font name: UserDefaultsManagement stores nil for system font
        if let fontName = UserDefaultsManagement.fontName {
            shared.noteFontName = fontName
        } else {
            shared.noteFontName = nil
        }

        save()
        UserDefaults.standard.set(true, forKey: key)
    }
}
