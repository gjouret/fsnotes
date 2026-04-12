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
//  - Zero `.kern`. No clear-color foreground (space is inherently invisible).
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
        // Render a single space with the .horizontalRule attribute.
        // The LayoutManager's drawBackground draws a full-width 4px line
        // over this range. Using a space instead of box-drawing chars
        // means the rule width is determined by the LayoutManager (which
        // knows the actual container width), not by a fixed glyph count.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .horizontalRule: true
        ]
        return NSAttributedString(string: " ", attributes: attrs)
    }
}
