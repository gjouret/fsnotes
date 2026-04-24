//
//  InlineMathBaselineTests.swift
//  FSNotesTests
//
//  Regression test for the inline-math attachment baseline bug.
//
//  Reported: rendered inline MathJax images (e.g. `(a ≠ 0)`) sit
//  noticeably ABOVE the baseline of the surrounding text.
//
//  Root cause: the inline-math hydration site used a "center on line box"
//  formula (`y = -(scaledSize.height - lineHeight) / 2`) instead of
//  aligning the image's interior baseline with the text baseline.
//
//  Fix: `InlineMathBaseline.bounds(imageSize:font:)` — a pure helper
//  that computes `y = -abs(font.descender)` so the image's bottom edge
//  sits at the text descender, landing the math glyphs on the text
//  baseline.
//
//  The live hydration site in `EditTextView+BlockModel.swift` should
//  call this helper. That wire-in is coordinated separately because the
//  hydration file was off-limits during this change.
//

import XCTest
import AppKit
@testable import FSNotes

final class InlineMathBaselineTests: XCTestCase {

    // MARK: - Helpers

    /// Read the font descender the same way the helper does.
    /// `NSFont.descender` is negative (points below baseline), so the
    /// helper takes `abs()`. Keep that contract explicit in tests.
    private func expectedDescent(for font: NSFont) -> CGFloat {
        return abs(font.descender)
    }

    // MARK: - bounds.y reflects the text descender (the actual bug)

    /// The former formula (`y = -(scaledSize.height - lineHeight) / 2`)
    /// returned a y value that depended on the *image* size, which for a
    /// tall-ish MathJax render centred the image on the line box rather
    /// than on the text baseline — the reported "sits too high" symptom.
    ///
    /// The corrected helper returns `y = -descent`, independent of the
    /// image height. This test locks that in.
    func test_boundsY_equalsNegativeFontDescender_forSystem14() {
        let font = NSFont.systemFont(ofSize: 14)
        let imageSize = CGSize(width: 30, height: 17)  // arbitrary — shape should not affect y

        let rect = InlineMathBaseline.bounds(imageSize: imageSize, font: font)

        XCTAssertEqual(rect.origin.y, -expectedDescent(for: font), accuracy: 0.001,
                       "bounds.y must push the image down by the font descender so its bottom lands at the text descender, not the text baseline.")
    }

    /// The y offset must scale with the font — a larger font has a larger
    /// descender and therefore a larger (more negative) y. This ensures
    /// the helper isn't hardcoded to one font size.
    func test_boundsY_scalesWithFontDescender() {
        let imageSize = CGSize(width: 50, height: 20)
        let smallFont = NSFont.systemFont(ofSize: 11)
        let largeFont = NSFont.systemFont(ofSize: 24)

        let smallRect = InlineMathBaseline.bounds(imageSize: imageSize, font: smallFont)
        let largeRect = InlineMathBaseline.bounds(imageSize: imageSize, font: largeFont)

        XCTAssertLessThan(largeRect.origin.y, smallRect.origin.y,
                          "A larger font has a larger descender (further below baseline), so the y offset must be MORE NEGATIVE for the larger font.")
        XCTAssertEqual(smallRect.origin.y, -expectedDescent(for: smallFont), accuracy: 0.001)
        XCTAssertEqual(largeRect.origin.y, -expectedDescent(for: largeFont), accuracy: 0.001)
    }

    /// The y offset must be strictly negative — a non-negative y leaves
    /// the image floating at or above the text baseline, which reproduces
    /// the original bug.
    func test_boundsY_isAlwaysNegative() {
        for pointSize in [10.0, 12.0, 14.0, 16.0, 18.0, 24.0] {
            let font = NSFont.systemFont(ofSize: CGFloat(pointSize))
            let rect = InlineMathBaseline.bounds(imageSize: CGSize(width: 40, height: 15), font: font)
            XCTAssertLessThan(rect.origin.y, 0,
                              "bounds.y must be negative for a \(pointSize)pt font; otherwise the image renders too high.")
        }
    }

    // MARK: - size passthrough — bounds must not alter the image dimensions

    func test_boundsSize_matchesImageSize_exactly() {
        let font = NSFont.systemFont(ofSize: 14)
        let imageSize = CGSize(width: 37.5, height: 18.25)

        let rect = InlineMathBaseline.bounds(imageSize: imageSize, font: font)

        XCTAssertEqual(rect.size.width, imageSize.width, accuracy: 0.001,
                       "Width must be the image width — anything else stretches the math.")
        XCTAssertEqual(rect.size.height, imageSize.height, accuracy: 0.001,
                       "Height must be the image height — anything else crops or stretches the math.")
    }

    func test_boundsOriginX_isZero() {
        let font = NSFont.systemFont(ofSize: 14)
        let rect = InlineMathBaseline.bounds(imageSize: CGSize(width: 30, height: 17), font: font)
        XCTAssertEqual(rect.origin.x, 0, accuracy: 0.001,
                       "bounds.x anchors the image to the text baseline origin; no horizontal inset.")
    }

    // MARK: - Purity — same input → byte-equal output

    func test_bounds_isPureFunction() {
        let font = NSFont.systemFont(ofSize: 14)
        let imageSize = CGSize(width: 30, height: 17)
        let a = InlineMathBaseline.bounds(imageSize: imageSize, font: font)
        let b = InlineMathBaseline.bounds(imageSize: imageSize, font: font)
        XCTAssertEqual(a, b, "Helper must be a pure function — repeated calls must return byte-equal rects.")
    }

    // MARK: - Regression vs. the old formula

    /// Reproduce the old "center on line box" formula and prove it differs
    /// from the new formula for a non-trivial inline expression. This
    /// guards against accidentally reverting to the broken shape.
    func test_newFormula_differsFromOldCenterOnLineBoxFormula() {
        let font = NSFont.systemFont(ofSize: 14)
        let lineHeight: CGFloat = 14  // old code read `font.pointSize` under this name
        let scaledSize = CGSize(width: 30, height: 17)  // inline math typically ~1.2× line height

        // The bug's formula:
        let oldY = -(scaledSize.height - lineHeight) / 2

        let newRect = InlineMathBaseline.bounds(imageSize: scaledSize, font: font)

        XCTAssertNotEqual(oldY, newRect.origin.y,
                          "If the new y matches the old 'center on line box' y, the bug has returned.")
        // And the new y must be more negative than the old y — we want to
        // sink the image more, not less.
        XCTAssertLessThan(newRect.origin.y, oldY,
                          "New formula must push the image DOWN relative to the old center-on-line-box formula; otherwise it won't fix the 'floats too high' symptom.")
    }
}
