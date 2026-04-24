//
//  ThemeTests.swift
//  FSNotesTests
//
//  Phase 7.1 — Theme struct + default JSON + loader (additive slice).
//
//  These tests exercise the Codable round-trip, hex parsing, dark/light
//  variant decoding, validation, and fallback behaviour of the new
//  Theme layer. They do NOT exercise renderer/fragment wiring (that's
//  Phase 7.2–7.3).
//

import XCTest
@testable import FSNotes

class ThemeTests: XCTestCase {

    // MARK: - 7.1: default JSON round-trip

    /// Load the bundled default theme + re-encode + decode again, and
    /// assert the nested groups are equal round-trip. We use
    /// decode-equal (not byte-identical) since JSONEncoder may reorder
    /// keys.
    func test_phase7_1_theme_defaultJSONRoundTrip() throws {
        let (theme, nested) = BlockStyleTheme.loadBundledDefault()

        // Re-encode both flat + nested into one payload, decode again.
        let data = try BlockStyleTheme.toJSON(theme: theme, nested: nested)
        let (theme2, nested2) = try BlockStyleTheme.theme(fromJSON: data)

        XCTAssertEqual(theme, theme2, "Flat BlockStyleTheme must round-trip")
        XCTAssertEqual(nested, nested2, "Nested groups must round-trip")
    }

    /// Load the bundled default theme and verify the key flat values
    /// match the existing hardcoded `BlockStyleTheme.default` — i.e.
    /// loading the default theme is a visual no-op.
    func test_phase7_1_theme_defaultMatchesCompiledIn() throws {
        let (theme, _) = BlockStyleTheme.loadBundledDefault()
        let compiled = BlockStyleTheme.default

        XCTAssertEqual(theme.noteFontSize, compiled.noteFontSize)
        XCTAssertEqual(theme.codeFontName, compiled.codeFontName)
        XCTAssertEqual(theme.codeFontSize, compiled.codeFontSize)
        XCTAssertEqual(theme.paragraphSpacing, compiled.paragraphSpacing)
        XCTAssertEqual(theme.headingFontScales, compiled.headingFontScales)
        XCTAssertEqual(theme.headingSpacingBefore, compiled.headingSpacingBefore)
        XCTAssertEqual(theme.headingSpacingAfter, compiled.headingSpacingAfter)
        XCTAssertEqual(theme.blockquoteBarWidth, compiled.blockquoteBarWidth)
        XCTAssertEqual(theme.lineWidth, compiled.lineWidth)
    }

    // MARK: - 7.1: malformed JSON falls back to default

    func test_phase7_1_theme_invalidJSONFallsBackToDefault() throws {
        // Write junk to a temp URL and load from it.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("invalid-theme-\(UUID().uuidString).json")
        try Data("this is not json { [ ] } :".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Must NOT throw; must return a usable theme.
        let (theme, nested) = BlockStyleTheme.load(from: tmp)

        // Fallback theme should match the compiled-in / bundled defaults.
        XCTAssertEqual(theme.noteFontSize, BlockStyleTheme.default.noteFontSize)
        XCTAssertGreaterThan(nested.typography.bodyFontSize, 0)
    }

    func test_phase7_1_theme_missingFileFallsBackToDefault() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        let (theme, nested) = BlockStyleTheme.load(from: missing)
        XCTAssertEqual(theme.noteFontSize, BlockStyleTheme.default.noteFontSize)
        XCTAssertGreaterThan(nested.typography.bodyFontSize, 0)
    }

    func test_phase7_1_theme_nilURLReturnsDefault() throws {
        let (theme, nested) = BlockStyleTheme.load(from: nil)
        XCTAssertEqual(theme.codeFontName, BlockStyleTheme.default.codeFontName)
        XCTAssertGreaterThan(nested.chrome.blockquoteBarWidth, 0)
    }

    // MARK: - 7.1: hex color parsing

    func test_phase7_1_theme_hexColorParsing() throws {
        // 6-digit hex, no alpha.
        let white = ThemeColor.parseHex("#FFFFFF")
        XCTAssertNotNil(white, "#FFFFFF must parse")

        // 8-digit hex with alpha.
        let whiteAlpha = ThemeColor.parseHex("#FFFFFFFF")
        XCTAssertNotNil(whiteAlpha, "#FFFFFFFF must parse")

        // Lowercase should also parse.
        let red = ThemeColor.parseHex("#ff0000")
        XCTAssertNotNil(red, "#ff0000 must parse")

        // No-# prefix also allowed.
        let blue = ThemeColor.parseHex("0000FF")
        XCTAssertNotNil(blue, "0000FF (no #) must parse")

        // Invalid hex digit must return nil (not crash).
        let bad = ThemeColor.parseHex("#GGGGGG")
        XCTAssertNil(bad, "#GGGGGG must NOT parse")

        // Wrong length must return nil.
        XCTAssertNil(ThemeColor.parseHex("#FFF"), "3-digit hex unsupported")
        XCTAssertNil(ThemeColor.parseHex("#FFFFF"), "5-digit hex unsupported")
        XCTAssertNil(ThemeColor.parseHex("#FFFFFFF"), "7-digit hex unsupported")
        XCTAssertNil(ThemeColor.parseHex(""), "empty hex must not parse")
    }

    func test_phase7_1_theme_hexColorComponents() throws {
        // Parse a known color and verify components.
        guard let red = ThemeColor.parseHex("#FF0000") else {
            XCTFail("#FF0000 must parse")
            return
        }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(OSX)
        red.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        red.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        XCTAssertEqual(r, 1.0, accuracy: 0.01)
        XCTAssertEqual(g, 0.0, accuracy: 0.01)
        XCTAssertEqual(b, 0.0, accuracy: 0.01)
        XCTAssertEqual(a, 1.0, accuracy: 0.01)

        // 8-digit with alpha = 0x80 = 128/255 ≈ 0.502
        guard let semi = ThemeColor.parseHex("#00FF0080") else {
            XCTFail("#00FF0080 must parse")
            return
        }
        semi.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 0.0, accuracy: 0.01)
        XCTAssertEqual(g, 1.0, accuracy: 0.01)
        XCTAssertEqual(b, 0.0, accuracy: 0.01)
        XCTAssertEqual(a, 128.0 / 255.0, accuracy: 0.01)
    }

    // MARK: - 7.1: dark/light variant decoding

    func test_phase7_1_theme_darkLightVariants() throws {
        // Single hex string — both modes resolve to the same color.
        let compact = "\"#FF0000\""
        let compactColor = try JSONDecoder().decode(
            ThemeColor.self, from: Data(compact.utf8)
        )
        XCTAssertEqual(compactColor.light, "#FF0000")
        XCTAssertNil(compactColor.dark)

        // {light, dark} pair — both decoded.
        let pair = "{\"light\":\"#007AFF\",\"dark\":\"#0A84FF\"}"
        let pairColor = try JSONDecoder().decode(
            ThemeColor.self, from: Data(pair.utf8)
        )
        XCTAssertEqual(pairColor.light, "#007AFF")
        XCTAssertEqual(pairColor.dark, "#0A84FF")

        // Asset reference — neither hex set.
        let asset = "{\"asset\":\"linkColor\"}"
        let assetColor = try JSONDecoder().decode(
            ThemeColor.self, from: Data(asset.utf8)
        )
        XCTAssertEqual(assetColor.asset, "linkColor")
        XCTAssertNil(assetColor.light)
        XCTAssertNil(assetColor.dark)

        // Resolved picks the right variant.
        let lightResolved = pairColor.resolved(dark: false)
        let darkResolved = pairColor.resolved(dark: true)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        lightResolved.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        darkResolved.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        // Different variants must produce different colors.
        XCTAssertNotEqual(r1, r2, accuracy: 0.001)
    }

    func test_phase7_1_theme_darkFallsBackToLightWhenAbsent() throws {
        let pair = "\"#111111\""
        let color = try JSONDecoder().decode(
            ThemeColor.self, from: Data(pair.utf8)
        )
        let dark = color.resolved(dark: true)
        let light = color.resolved(dark: false)
        // When only `light` is present, dark resolves to the same value.
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        dark.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        light.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        XCTAssertEqual(r1, r2, accuracy: 0.001)
        XCTAssertEqual(g1, g2, accuracy: 0.001)
        XCTAssertEqual(b1, b2, accuracy: 0.001)
    }

    // MARK: - 7.1: out-of-range validation

    func test_phase7_1_theme_outOfRangeFontSize() throws {
        // Negative body font size must be rejected.
        var nested = ThemeNestedGroups.default
        nested.typography.bodyFontSize = -1
        XCTAssertThrowsError(try nested.validate()) { error in
            guard case ThemeLoadError.invalid = error else {
                XCTFail("Expected .invalid, got \(error)")
                return
            }
        }

        // Zero code font size must be rejected.
        nested = ThemeNestedGroups.default
        nested.typography.codeFontSize = 0
        XCTAssertThrowsError(try nested.validate())

        // Zero heading font in `headingFontSizes` array must be rejected.
        nested = ThemeNestedGroups.default
        nested.typography.headingFontSizes = [28, 0, 18, 16, 14, 13]
        XCTAssertThrowsError(try nested.validate())

        // Negative HR thickness must be rejected.
        nested = ThemeNestedGroups.default
        nested.chrome.hrThickness = -1
        XCTAssertThrowsError(try nested.validate())

        // Zero lineHeightMultiple must be rejected.
        nested = ThemeNestedGroups.default
        nested.spacing.lineHeightMultiple = 0
        XCTAssertThrowsError(try nested.validate())

        // Valid defaults must pass.
        XCTAssertNoThrow(try ThemeNestedGroups.default.validate())
    }

    /// End-to-end: JSON containing an invalid value must throw through
    /// `Theme.theme(fromJSON:)` but fall back through `Theme.load(from:)`.
    func test_phase7_1_theme_invalidJSONValidation() throws {
        let badJSON = """
        {
            "noteFontName": null,
            "noteFontSize": 14,
            "codeFontName": "Source Code Pro",
            "codeFontSize": 14,
            "editorLineSpacing": 4,
            "lineWidth": 1000,
            "marginSize": 20,
            "headingFontScales": [2.0, 1.7, 1.4, 1.2, 1.1, 1.05],
            "headingSpacingBefore": [1.2, 1.0, 0.9, 0.8, 0.7, 0.6],
            "headingSpacingAfter": [0.67, 0.5, 0.4, 0.35, 0.3, 0.25],
            "paragraphSpacing": 12,
            "codeBlockLineSpacing": 0,
            "codeBlockParagraphSpacing": 16,
            "codeBlockSpacingBefore": 0,
            "listIndentScale": 1.8,
            "listCellScale": 2.0,
            "listBulletSizeScale": 0.7,
            "listNumberDrawScale": 1.0,
            "listCheckboxDrawScale": 1.2,
            "listBulletStrokeInset": 0.5,
            "listBulletStrokeWidth": 1.0,
            "listBlockSpacing": 16,
            "blockquoteBarInitialOffset": 2,
            "blockquoteBarSpacing": 10,
            "blockquoteBarWidth": 4,
            "blockquoteGapAfterBars": 4,
            "blockquoteBlockSpacing": 16,
            "tablePlaceholderWidth": 400,
            "tablePlaceholderHeight": 100,
            "tableBlockSpacing": 16,
            "hrBlockSpacing": 16,
            "htmlBlockLineSpacing": 0,
            "htmlBlockParagraphSpacing": 16,
            "htmlBlockSpacingBefore": 0,
            "highlightColor": {"red": 1, "green": 1, "blue": 0, "alpha": 0.5},
            "blankLineMinHeight": 0.01,
            "blankLineMaxHeight": 0.01,
            "typography": {
                "bodyFontName": null,
                "bodyFontSize": -1,
                "codeFontName": "Source Code Pro",
                "codeFontSize": 14,
                "kbdFontSizeMultiplier": 0.85,
                "subSuperFontSizeMultiplier": 0.75,
                "inlineCodeSizeMultiplier": 1.0,
                "boldMarker": "**",
                "italicMarker": "*"
            }
        }
        """

        // Strict parse: validation must throw.
        XCTAssertThrowsError(try BlockStyleTheme.theme(fromJSON: Data(badJSON.utf8)))

        // Lenient load: must fall back to default (no throw).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-of-range-\(UUID().uuidString).json")
        try Data(badJSON.utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let (theme, _) = BlockStyleTheme.load(from: tmp)
        XCTAssertGreaterThan(
            theme.noteFontSize, 0,
            "Fallback theme must have a sensible body font size"
        )
    }

    // MARK: - 7.1: loader chain (URL → bundled → compiled-in)

    func test_phase7_1_theme_userOverrideLoads() throws {
        // Write a valid theme with a single field changed, load it,
        // verify the override wins.
        let (_, nested) = BlockStyleTheme.loadBundledDefault()
        var custom = BlockStyleTheme.default
        custom.paragraphSpacing = 99
        var customNested = nested
        customNested.typography.bodyFontSize = 17

        let data = try BlockStyleTheme.toJSON(theme: custom, nested: customNested)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("override-\(UUID().uuidString).json")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let (loaded, loadedNested) = BlockStyleTheme.load(from: tmp)
        XCTAssertEqual(loaded.paragraphSpacing, 99)
        XCTAssertEqual(loadedNested.typography.bodyFontSize, 17)
    }

    // MARK: - 7.1: nested group synthesis from flat-only JSON

    func test_phase7_1_theme_flatOnlyJSONSynthesizesNested() throws {
        // A legacy flat-only payload (no `typography` / `spacing` /
        // `colors` / `chrome` blocks) should still decode cleanly, with
        // the nested groups synthesized from the flat values.
        let flatOnly = """
        {
            "noteFontName": null,
            "noteFontSize": 16,
            "codeFontName": "Menlo",
            "codeFontSize": 13,
            "editorLineSpacing": 4,
            "lineWidth": 1000,
            "marginSize": 20,
            "headingFontScales": [2.0, 1.7, 1.4, 1.2, 1.1, 1.05],
            "headingSpacingBefore": [1.2, 1.0, 0.9, 0.8, 0.7, 0.6],
            "headingSpacingAfter": [0.67, 0.5, 0.4, 0.35, 0.3, 0.25],
            "paragraphSpacing": 18,
            "codeBlockLineSpacing": 0,
            "codeBlockParagraphSpacing": 16,
            "codeBlockSpacingBefore": 0,
            "listIndentScale": 1.8,
            "listCellScale": 2.0,
            "listBulletSizeScale": 0.7,
            "listNumberDrawScale": 1.0,
            "listCheckboxDrawScale": 1.2,
            "listBulletStrokeInset": 0.5,
            "listBulletStrokeWidth": 1.0,
            "listBlockSpacing": 16,
            "blockquoteBarInitialOffset": 2,
            "blockquoteBarSpacing": 10,
            "blockquoteBarWidth": 4,
            "blockquoteGapAfterBars": 4,
            "blockquoteBlockSpacing": 16,
            "tablePlaceholderWidth": 400,
            "tablePlaceholderHeight": 100,
            "tableBlockSpacing": 16,
            "hrBlockSpacing": 16,
            "htmlBlockLineSpacing": 0,
            "htmlBlockParagraphSpacing": 16,
            "htmlBlockSpacingBefore": 0,
            "highlightColor": {"red": 1, "green": 0.9, "blue": 0, "alpha": 0.5},
            "blankLineMinHeight": 0.01,
            "blankLineMaxHeight": 0.01
        }
        """

        let (theme, nested) = try BlockStyleTheme.theme(
            fromJSON: Data(flatOnly.utf8)
        )

        // Flat field is honored.
        XCTAssertEqual(theme.codeFontName, "Menlo")
        XCTAssertEqual(theme.noteFontSize, 16)
        XCTAssertEqual(theme.paragraphSpacing, 18)

        // Nested fields are synthesized from the flat values.
        XCTAssertEqual(nested.typography.codeFontName, "Menlo")
        XCTAssertEqual(nested.typography.bodyFontSize, 16)
        XCTAssertEqual(nested.spacing.paragraphSpacing, 18)
    }
}
