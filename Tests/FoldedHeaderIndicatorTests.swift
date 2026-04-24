//
//  FoldedHeaderIndicatorTests.swift
//  FSNotesTests
//
//  Regression coverage for the `[...]` visual indicator drawn at the
//  trailing edge of a folded heading by `HeadingLayoutFragment`.
//
//  The indicator is cosmetic — it has no hit-test or interactivity —
//  so the tests focus on the pure geometry helper
//  `HeadingLayoutFragment.indicatorRect(folded:…)` rather than the
//  full draw path. Helper is pure on value types so there's no TK2
//  delegate / NSWindow setup to stand up.
//

import XCTest
import AppKit
@testable import FSNotes

final class FoldedHeaderIndicatorTests: XCTestCase {

    // MARK: - Helpers

    /// Build a fresh `ThemeChrome` with default values. Isolated so
    /// theme-mutation tests can subclass and override.
    private func defaultChrome() -> ThemeChrome {
        return ThemeChrome.default
    }

    /// Synthetic last-line typographic bounds — a 100×20 box starting
    /// at the origin. The fragment's local coordinate system has the
    /// heading's baseline running along the middle of this rect.
    private let sampleLastLineBounds = CGRect(x: 0, y: 0, width: 100, height: 20)

    // MARK: - Nil when unfolded

    /// The helper must return `nil` when `folded == false` regardless
    /// of whatever line bounds / font size are passed. This prevents
    /// the indicator from accidentally appearing on expanded headings.
    func test_indicatorRect_returnsNil_whenNotFolded() {
        let rect = HeadingLayoutFragment.indicatorRect(
            folded: false,
            lastLineTypographicBounds: sampleLastLineBounds,
            bodyFontSize: 28.0,
            chrome: defaultChrome()
        )
        XCTAssertNil(
            rect,
            "indicatorRect must return nil when heading is not folded"
        )
    }

    // MARK: - Non-nil + positive size when folded

    /// When folded, the helper must return a non-nil rect with
    /// positive width + height. The chip needs room to hold the "..."
    /// glyphs plus padding.
    func test_indicatorRect_returnsPositiveSizedRect_whenFolded() {
        let chrome = defaultChrome()
        let rect = HeadingLayoutFragment.indicatorRect(
            folded: true,
            lastLineTypographicBounds: sampleLastLineBounds,
            bodyFontSize: 28.0,
            chrome: chrome
        )
        XCTAssertNotNil(
            rect,
            "indicatorRect must return a rect when heading is folded"
        )
        guard let rect else { return }

        XCTAssertGreaterThan(
            rect.width, 0,
            "Indicator chip must have positive width; got \(rect.width)"
        )
        XCTAssertGreaterThan(
            rect.height, 0,
            "Indicator chip must have positive height; got \(rect.height)"
        )

        // The chip height must fit around the measured text plus both
        // vertical paddings. A lower bound of `2 * padV` plus any
        // positive text height is sufficient.
        XCTAssertGreaterThanOrEqual(
            rect.height,
            2 * chrome.foldedHeaderIndicatorVerticalPadding,
            "Chip height must include top + bottom padding"
        )
    }

    // MARK: - Trailing placement

    /// The chip must sit to the RIGHT of the heading's last line —
    /// specifically at `lastLine.maxX + trailingGap` — not overlap the
    /// heading glyphs.
    func test_indicatorRect_sitsToRightOfLastLine_withTrailingGap() {
        let chrome = defaultChrome()
        let rect = HeadingLayoutFragment.indicatorRect(
            folded: true,
            lastLineTypographicBounds: sampleLastLineBounds,
            bodyFontSize: 28.0,
            chrome: chrome
        )
        guard let rect else {
            XCTFail("Expected non-nil rect")
            return
        }

        let expectedX = sampleLastLineBounds.maxX
            + chrome.foldedHeaderIndicatorTrailingGap
        XCTAssertEqual(
            rect.origin.x, expectedX,
            accuracy: 0.001,
            "Indicator chip must sit at lastLine.maxX + trailingGap"
        )
    }

    // MARK: - Vertical centering

    /// The chip must be vertically centered against the heading's last
    /// line — its midY equals the line's midY so the chip visually
    /// aligns with the heading baseline area rather than sitting above
    /// or below it.
    func test_indicatorRect_isVerticallyCenteredAgainstLastLine() {
        let chrome = defaultChrome()
        let rect = HeadingLayoutFragment.indicatorRect(
            folded: true,
            lastLineTypographicBounds: sampleLastLineBounds,
            bodyFontSize: 28.0,
            chrome: chrome
        )
        guard let rect else {
            XCTFail("Expected non-nil rect")
            return
        }
        XCTAssertEqual(
            rect.midY,
            sampleLastLineBounds.midY,
            accuracy: 0.001,
            "Indicator chip midY must equal line midY " +
            "(expected \(sampleLastLineBounds.midY), got \(rect.midY))"
        )
    }

    // MARK: - Font-size scaling

    /// Doubling the body font size must produce a LARGER chip. Exact
    /// ratio depends on AppKit's text-measurement rounding — tests
    /// only that larger body font ⇒ larger chip, not a precise
    /// multiplier (which would brittle-pin to rendering details).
    func test_indicatorRect_scalesWithBodyFontSize() {
        let chrome = defaultChrome()
        let small = HeadingLayoutFragment.indicatorRect(
            folded: true,
            lastLineTypographicBounds: sampleLastLineBounds,
            bodyFontSize: 14.0,
            chrome: chrome
        )
        let large = HeadingLayoutFragment.indicatorRect(
            folded: true,
            lastLineTypographicBounds: sampleLastLineBounds,
            bodyFontSize: 28.0,
            chrome: chrome
        )
        guard let small, let large else {
            XCTFail("Both rects must be non-nil")
            return
        }
        XCTAssertGreaterThan(
            large.width, small.width,
            "Larger body font must produce a larger chip width"
        )
        XCTAssertGreaterThan(
            large.height, small.height,
            "Larger body font must produce a larger chip height"
        )
    }

    // MARK: - Indicator text

    /// Guard against accidental reshuffling of the displayed chip
    /// text. Three ASCII dots is the canonical form.
    func test_indicatorText_isThreeAsciiDots() {
        XCTAssertEqual(
            HeadingLayoutFragment.indicatorText, "...",
            "Folded-header chip must render three ASCII dots"
        )
    }
}
