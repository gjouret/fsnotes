//
//  InlineMathBaseline.swift
//  FSNotesCore
//
//  Pure helper that computes the correct `NSTextAttachment.bounds` for an
//  inline-math (MathJax) rendered image so the image's internal baseline
//  aligns with the surrounding text baseline.
//
//  THE BUG THIS FIXES:
//  The earlier formula used by the inline-math attachment hydration path
//  (`EditTextView+BlockModel.swift`) was
//
//      y = -(scaledSize.height - lineHeight) / 2     // centers on line box
//
//  which centers the image on the line box rather than on the text
//  baseline. For a small expression like `(a ≠ 0)` rendered at a size
//  slightly taller than the body font, this lifts the image noticeably
//  ABOVE the baseline of the surrounding text — the reported visual
//  symptom.
//
//  WHY THE FIX LIVES HERE:
//  - Pure function of (imageSize, font) → CGRect.
//  - No AppKit view, layout manager, or storage involved — easy to unit
//    test without rendering real MathJax.
//  - The hydration site in `EditTextView+BlockModel.swift` will call this
//    helper instead of inlining its own formula, preventing the "every
//    attachment site invents its own ad-hoc offset" drift pattern.
//
//  THE FORMULA:
//  `NSTextAttachment.bounds.y == 0` anchors the image's BOTTOM edge on
//  the text baseline, which places the whole image above the baseline.
//  To align the image's interior baseline with the text baseline we sink
//  the image by the image's below-baseline descent.
//
//  The rendered MathJax CHTML expression's descent-below-internal-baseline
//  is not known precisely without measuring the SVG, but it tracks the
//  host font's descender closely: MathJax typesets at the body's
//  `font-size` (the HTML template uses 14px, matching the default body
//  font), so the math font's descender is ~= the text font's descender.
//  Using `-abs(font.descender)` as the y offset places the image's
//  bottom at the text descender, which visually lands the math bulk on
//  the text baseline for the overwhelming majority of inline expressions.
//
//  Pure function: same input → byte-equal output. Same inputs on the
//  same machine produce the same rect — `font.descender` is a metric
//  read, not a computation.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum InlineMathBaseline {

    /// Compute the `NSTextAttachment.bounds` for an inline-math image so
    /// the image's internal baseline lands on the surrounding text
    /// baseline.
    ///
    /// - Parameters:
    ///   - imageSize: the size of the rendered MathJax bitmap (after any
    ///     scale-to-line-height adjustment the caller has applied).
    ///   - font: the body font of the run the image is embedded in.
    ///     `font.descender` is the metric the formula depends on.
    /// - Returns: a rect with `origin.x == 0`, `size == imageSize`, and
    ///   `origin.y == -abs(font.descender)`. The negative y pushes the
    ///   image DOWN so its bottom sits at the text descender rather than
    ///   at the text baseline.
    public static func bounds(imageSize: CGSize, font: PlatformFont) -> CGRect {
        let descent = abs(font.descender)
        return CGRect(
            x: 0,
            y: -descent,
            width: imageSize.width,
            height: imageSize.height
        )
    }
}
