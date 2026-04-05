//
//  ListRenderer.swift
//  FSNotesCore
//
//  Renders a Block.list into an NSAttributedString.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: [ListItem] tree + body font.
//  - Output: NSAttributedString where each item appears on its own
//    line, prefixed by a VISUAL bullet marker, indented by nesting
//    depth. The source markers (`-`, `*`, `+`, `1.`, `2)`) are
//    CONSUMED by the parser — they do NOT appear in the rendered
//    output. For unordered items we emit a "• " glyph; for ordered
//    items we emit the parsed ordinal as "N. ".
//  - Zero `.kern`. Zero clear-color foreground.
//  - Pure function: same input → byte-equal output.
//
//  Visual indentation is two spaces per nesting level — INDEPENDENT
//  of the source indent. This is intentional: the block model stores
//  the original indent for round-trip serialization, but the renderer
//  normalizes indentation so the displayed output is consistent
//  across mixed-indent source files.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum ListRenderer {

    /// Width of one level of visual indentation (space characters).
    private static let indentWidth = 2

    /// Render a list to an attributed string. The output is a
    /// newline-separated sequence of rendered items, with no trailing
    /// newline — callers compose list output with sibling blocks via
    /// the usual block-joining newline.
    public static func render(
        items: [ListItem],
        bodyFont: PlatformFont
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        renderItems(items, depth: 0, bodyFont: bodyFont, into: out)
        // Remove the trailing "\n" that the last item appended — the
        // block-join layer owns inter-block separators.
        if out.length > 0, out.string.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    private static func renderItems(
        _ items: [ListItem],
        depth: Int,
        bodyFont: PlatformFont,
        into out: NSMutableAttributedString
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: PlatformColor.label
        ]
        for item in items {
            let indent = String(repeating: " ", count: depth * indentWidth)
            let bullet = visualBullet(for: item.marker)
            let prefix = indent + bullet + " "
            out.append(NSAttributedString(string: prefix, attributes: attrs))
            out.append(InlineRenderer.render(item.inline, baseAttributes: attrs))
            out.append(NSAttributedString(string: "\n", attributes: attrs))
            if !item.children.isEmpty {
                renderItems(item.children, depth: depth + 1,
                            bodyFont: bodyFont, into: out)
            }
        }
    }

    /// Map a parsed source marker to its visual rendering.
    /// Unordered markers (`-`, `*`, `+`) all become "•". Ordered
    /// markers reuse the parsed "N." or "N)" text directly — that
    /// IS the visual form.
    private static func visualBullet(for marker: String) -> String {
        if marker == "-" || marker == "*" || marker == "+" {
            return "\u{2022}"   // •
        }
        return marker
    }
}
