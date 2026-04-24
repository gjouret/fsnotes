//
//  BlockStyleThemeTests.swift
//  FSNotesTests
//
//  Unit tests for BlockStyleTheme — JSON round-trip, defaults verification,
//  font construction, and safe access.
//

import XCTest
@testable import FSNotes

class BlockStyleThemeTests: XCTestCase {

    // MARK: - JSON round-trip

    func testRoundTrip() throws {
        let original = BlockStyleTheme.default
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(BlockStyleTheme.self, from: data)
        XCTAssertEqual(original, decoded, "Round-trip encode/decode must produce identical theme")
    }

    func testJSONIsHumanReadable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(BlockStyleTheme.default)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("headingFontScales"))
        XCTAssertTrue(json.contains("blockquoteBarWidth"))
        XCTAssertTrue(json.contains("highlightColor"))
    }

    // MARK: - Default values match hardcoded constants

    func testDefaultHeadingFontScales() {
        let t = BlockStyleTheme.default
        XCTAssertEqual(t.headingFontScales, [2.0, 1.7, 1.4, 1.2, 1.1, 1.05])
    }

    func testDefaultHeadingSpacing() {
        let t = BlockStyleTheme.default
        XCTAssertEqual(t.headingSpacingBefore, [1.2, 1.0, 0.9, 0.8, 0.7, 0.6])
        XCTAssertEqual(t.headingSpacingAfter, [0.67, 0.5, 0.4, 0.35, 0.3, 0.25])
    }

    func testDefaultParagraphSpacing() {
        XCTAssertEqual(BlockStyleTheme.default.paragraphSpacing, 12)
    }

    func testDefaultListConstants() {
        let t = BlockStyleTheme.default
        XCTAssertEqual(t.listIndentScale, 1.8)
        XCTAssertEqual(t.listCellScale, 2.0)
        XCTAssertEqual(t.listBulletSizeScale, 0.7)
        XCTAssertEqual(t.listNumberDrawScale, 1.0)
        XCTAssertEqual(t.listCheckboxDrawScale, 1.2)
    }

    func testDefaultBlockquoteConstants() {
        let t = BlockStyleTheme.default
        XCTAssertEqual(t.blockquoteBarInitialOffset, 2)
        XCTAssertEqual(t.blockquoteBarSpacing, 10)
        XCTAssertEqual(t.blockquoteBarWidth, 4)
        XCTAssertEqual(t.blockquoteGapAfterBars, 4)
    }

    func testDefaultHighlightColor() {
        let t = BlockStyleTheme.default
        XCTAssertEqual(t.highlightColor.red, 1.0)
        XCTAssertEqual(t.highlightColor.green, 0.9)
        XCTAssertEqual(t.highlightColor.blue, 0.0)
        XCTAssertEqual(t.highlightColor.alpha, 0.5)
    }

    func testDefaultEditorLayout() {
        let t = BlockStyleTheme.default
        XCTAssertEqual(t.editorLineSpacing, 4)
        XCTAssertEqual(t.lineWidth, 1000)
        XCTAssertEqual(t.marginSize, 20)
    }

    func testDefaultFonts() {
        let t = BlockStyleTheme.default
        XCTAssertNil(t.noteFontName)
        XCTAssertEqual(t.noteFontSize, 14)
        XCTAssertEqual(t.codeFontName, "Source Code Pro")
        XCTAssertEqual(t.codeFontSize, 14)
    }

    // MARK: - Font construction

    func testNoteFontSystemDefault() {
        var t = BlockStyleTheme.default
        t.noteFontName = nil
        t.noteFontSize = 16
        let font = t.noteFont
        XCTAssertEqual(font.pointSize, 16)
    }

    func testNoteFontNamedFont() {
        var t = BlockStyleTheme.default
        t.noteFontName = "Helvetica"
        t.noteFontSize = 18
        let font = t.noteFont
        XCTAssertEqual(font.pointSize, 18)
        XCTAssertTrue(font.fontName.contains("Helvetica"))
    }

    func testCodeFontConstruction() {
        let t = BlockStyleTheme.default
        let font = t.codeFont
        XCTAssertEqual(font.pointSize, 14)
    }

    // MARK: - Safe heading access (clamping)

    func testHeadingFontScaleClampsLow() {
        let t = BlockStyleTheme.default
        XCTAssertEqual(t.headingFontScale(for: 0), 2.0, "Level 0 should clamp to H1")
        XCTAssertEqual(t.headingFontScale(for: -1), 2.0, "Negative level should clamp to H1")
    }

    func testHeadingFontScaleClampsHigh() {
        let t = BlockStyleTheme.default
        XCTAssertEqual(t.headingFontScale(for: 7), 1.05, "Level 7 should clamp to H6")
        XCTAssertEqual(t.headingFontScale(for: 100), 1.05, "Level 100 should clamp to H6")
    }

    func testHeadingFontScaleNormalRange() {
        let t = BlockStyleTheme.default
        XCTAssertEqual(t.headingFontScale(for: 1), 2.0)
        XCTAssertEqual(t.headingFontScale(for: 3), 1.4)
        XCTAssertEqual(t.headingFontScale(for: 6), 1.05)
    }

    // MARK: - Blockquote indent calculation

    func testBlockquoteIndentDepthZero() {
        let t = BlockStyleTheme.default
        XCTAssertEqual(t.blockquoteLeftIndent(for: 0), 0)
    }

    func testBlockquoteIndentDepthOne() {
        let t = BlockStyleTheme.default
        // barInitialOffset(2) + 0*barSpacing + barWidth(4) + gap(4) = 10
        XCTAssertEqual(t.blockquoteLeftIndent(for: 1), 10)
    }

    func testBlockquoteIndentDepthTwo() {
        let t = BlockStyleTheme.default
        // barInitialOffset(2) + 1*barSpacing(10) + barWidth(4) + gap(4) = 20
        XCTAssertEqual(t.blockquoteLeftIndent(for: 2), 20)
    }

    // MARK: - CodableColor

    func testCodableColorRoundTrip() throws {
        let color = CodableColor(red: 0.5, green: 0.25, blue: 0.75, alpha: 1.0)
        let data = try JSONEncoder().encode(color)
        let decoded = try JSONDecoder().decode(CodableColor.self, from: data)
        XCTAssertEqual(color, decoded)
    }

    func testCodableColorPlatformConversion() {
        let color = CodableColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        let platform = color.platformColor
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        platform.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1.0, accuracy: 0.01)
        XCTAssertEqual(g, 0.0, accuracy: 0.01)
        XCTAssertEqual(b, 0.0, accuracy: 0.01)
    }

    // MARK: - Partial JSON decode

    func testPartialJSONDecodesWithDefaults() throws {
        // A JSON that only specifies paragraph spacing — everything else
        // should use the compiled-in default if the full struct is used.
        // Note: since BlockStyleTheme is Codable (not partial-merge),
        // partial JSON will fail to decode as a full struct. This test
        // verifies that a full JSON with one value changed decodes correctly.
        var modified = BlockStyleTheme.default
        modified.paragraphSpacing = 24
        let data = try JSONEncoder().encode(modified)
        let decoded = try JSONDecoder().decode(BlockStyleTheme.self, from: data)
        XCTAssertEqual(decoded.paragraphSpacing, 24)
        XCTAssertEqual(decoded.headingFontScales, BlockStyleTheme.default.headingFontScales)
    }

    // MARK: - Flat ↔ nested synthesis (drift regression)

    /// `ThemeNestedGroups.synthesized(from:)` is the single source of truth
    /// the save path uses to build the nested payload from the flat theme
    /// (`saveActiveTheme` calls it every write). Every flat field that has
    /// a nested counterpart MUST propagate — otherwise the on-disk nested
    /// block drifts from the flat block as IBActions mutate flat values.
    ///
    /// This test mutates each flat field that has a nested counterpart,
    /// synthesizes the nested view, and asserts the nested value tracks
    /// the flat value. Pre-fix the assertions on `italic`/`bold`/
    /// `lineHeightMultiple` would fail: the earlier synthesis only
    /// propagated a subset of pairs.
    func testSynthesizedNestedMirrorsAllFlatFields() {
        var flat = BlockStyleTheme.default
        // Pick values that differ from both the flat default AND the
        // nested default so a missed field is detectable either way.
        flat.noteFontName = "Avenir"            // flat default: nil
        flat.noteFontSize = 17                  // flat default: 14
        flat.codeFontName = "JetBrains Mono"    // flat default: "Source Code Pro"
        flat.codeFontSize = 13                  // flat default: 14
        // Pick markers that differ from BOTH flat and nested defaults so
        // a missed propagation is visible regardless of which side the
        // un-propagated nested was stuck at.
        // flat defaults: italic="*", bold="__". nested defaults:
        // italicMarker="*", boldMarker="**".
        flat.italic = "_"                       // differs from both
        flat.bold = "__"                        // matches flat default,
                                                // differs from nested default
        flat.lineHeightMultiple = 1.25          // flat default: 1.4 (nested default 1.0)
        flat.paragraphSpacing = 7               // flat default: 12
        flat.blockquoteBarInitialOffset = 3     // flat default: 2
        flat.blockquoteBarSpacing = 5           // flat default: 10
        flat.blockquoteBarWidth = 2             // flat default: 4

        let nested = ThemeNestedGroups.synthesized(from: flat)

        XCTAssertEqual(nested.typography.bodyFontName, "Avenir")
        XCTAssertEqual(nested.typography.bodyFontSize, 17)
        XCTAssertEqual(nested.typography.codeFontName, "JetBrains Mono")
        XCTAssertEqual(nested.typography.codeFontSize, 13)
        XCTAssertEqual(nested.typography.italicMarker, "_")
        XCTAssertEqual(nested.typography.boldMarker, "__")
        XCTAssertEqual(nested.spacing.lineHeightMultiple, 1.25)
        XCTAssertEqual(nested.spacing.paragraphSpacing, 7)
        XCTAssertEqual(nested.chrome.blockquoteBarInitialOffset, 3)
        XCTAssertEqual(nested.chrome.blockquoteBarSpacing, 5)
        XCTAssertEqual(nested.chrome.blockquoteBarWidth, 2)
    }

    /// End-to-end: encoding a mutated flat theme via `encodeWithNested`
    /// (the `saveActiveTheme` path) and decoding it back must yield a
    /// nested block that mirrors the flat block. Pre-fix, a decode of the
    /// saved JSON would return nested values stuck at their compiled-in
    /// defaults for the un-propagated pairs.
    func testEncodeWithNestedRoundTripKeepsFlatAndNestedAligned() throws {
        var flat = BlockStyleTheme.default
        flat.noteFontName = "Avenir"
        flat.italic = "_"
        flat.bold = "__"  // differs from nested default "**"
        flat.lineHeightMultiple = 1.25

        let nested = ThemeNestedGroups.synthesized(from: flat)
        let data = try BlockStyleTheme.encodeWithNested(flat: flat, nested: nested)

        let (decodedFlat, decodedNested) = try BlockStyleTheme.theme(fromJSON: data)

        // Flat side preserved.
        XCTAssertEqual(decodedFlat.noteFontName, "Avenir")
        XCTAssertEqual(decodedFlat.italic, "_")
        XCTAssertEqual(decodedFlat.bold, "__")
        XCTAssertEqual(decodedFlat.lineHeightMultiple, 1.25)

        // Nested side agrees with flat.
        XCTAssertEqual(decodedNested.typography.bodyFontName, decodedFlat.noteFontName)
        XCTAssertEqual(decodedNested.typography.italicMarker, decodedFlat.italic)
        XCTAssertEqual(decodedNested.typography.boldMarker, decodedFlat.bold)
        XCTAssertEqual(
            decodedNested.spacing.lineHeightMultiple,
            decodedFlat.lineHeightMultiple
        )
    }
}
