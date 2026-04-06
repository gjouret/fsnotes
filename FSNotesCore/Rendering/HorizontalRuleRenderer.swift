//
//  HorizontalRuleRenderer.swift
//  FSNotesCore
//
//  Renders a Block.horizontalRule into an NSAttributedString.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: none (HR carries no semantic content — the source chars
//    are pure markers).
//  - Output: a single visual glyph line ("─" U+2500 repeated, or a
//    placeholder the LayoutManager can draw over). The source chars
//    (`-`, `_`, `*`) are CONSUMED by the parser and NEVER reach the
//    rendered output.
//  - Zero `.kern`. Zero clear-color foreground.
//  - Pure function: same input → byte-equal output.
//
//  Rendering: emits a fixed-width run of "─" (box-drawing light
//  horizontal, U+2500). Source markers never appear in rendered output.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum HorizontalRuleRenderer {

    /// Number of box-drawing characters in the visual rule. Chosen
    /// as a readable default; the real layout renders a full-width
    /// line via the LayoutManager in a later phase.
    private static let visualWidth = 40

    public static func render(bodyFont: PlatformFont) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: PlatformColor.label
        ]
        let glyphs = String(repeating: "\u{2500}", count: visualWidth)
        return NSAttributedString(string: glyphs, attributes: attrs)
    }
}
