//
//  HeadingRenderer.swift
//  FSNotesCore
//
//  Renders a Block.heading into an NSAttributedString for display.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: heading level (1–6) + raw suffix (everything after the `#`
//    markers in the source line).
//  - Output: NSAttributedString containing ONLY the displayed heading
//    text (suffix trimmed of surrounding whitespace). Zero `#`
//    characters. Zero `.kern`. Zero clear-color foreground.
//  - Pure function: same input → byte-equal output.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum HeadingRenderer {

    /// Render a heading's displayed text.
    ///
    /// - Parameters:
    ///   - level: ATX heading level, 1–6.
    ///   - suffix: the raw text after the `#` markers (may begin with a
    ///     space, may be empty). The renderer trims surrounding
    ///     whitespace to produce the displayed text.
    ///   - bodyFont: the base font. Heading levels scale up from this.
    public static func render(
        level: Int,
        suffix: String,
        bodyFont: PlatformFont
    ) -> NSAttributedString {
        // Architectural invariant: the rendered string must contain ONLY
        // the displayed heading text. It MUST NOT contain `#` characters.
        let displayed = suffix.trimmingCharacters(in: .whitespaces)

        let font = headingFont(level: level, bodyFont: bodyFont)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: PlatformColor.label
        ]
        return InlineRenderer.render(
            [.text(displayed)],
            baseAttributes: attrs
        )
    }

    /// Heading font: derive a bold heading-scaled font from the body
    /// font. Levels 1–6 map to progressively smaller sizes.
    /// Scale factors match the source-mode renderer (NotesTextProcessor)
    /// so headings look identical in WYSIWYG and markdown modes.
    private static func headingFont(level: Int, bodyFont: PlatformFont) -> PlatformFont {
        let baseSize = bodyFont.pointSize
        let scale: CGFloat
        switch level {
        case 1: scale = 2.0
        case 2: scale = 1.7
        case 3: scale = 1.4
        case 4: scale = 1.2
        case 5: scale = 1.1
        default: scale = 1.05  // H6: slightly larger than body
        }
        let size = baseSize * scale
        #if os(OSX)
        let descriptor = bodyFont.fontDescriptor.withSymbolicTraits(.bold)
        return PlatformFont(descriptor: descriptor, size: size) ?? .boldSystemFont(ofSize: size)
        #else
        let descriptor = bodyFont.fontDescriptor.withSymbolicTraits(.traitBold)
            ?? bodyFont.fontDescriptor
        return PlatformFont(descriptor: descriptor, size: size)
        #endif
    }
}
