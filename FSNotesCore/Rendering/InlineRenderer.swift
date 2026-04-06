//
//  InlineRenderer.swift
//  FSNotesCore
//
//  Renders a tree of Inline nodes into an NSAttributedString. This is
//  the inline half of the block renderer: paragraphs, headings, list
//  items, etc. feed their [Inline] payload through here to build the
//  rendered text.
//
//  ARCHITECTURAL CONTRACT:
//  - Input: [Inline] tree + base attributes.
//  - Output: NSAttributedString containing ONLY the rendered text.
//    Zero markdown syntax markers (**bold**, _italic_, `code`, etc.
//    NEVER appear in the output — those markers are consumed by the
//    parser and turned into Inline cases).
//  - Pure function: same input → byte-equal output.
//

import Foundation
#if os(OSX)
import AppKit
#else
import UIKit
#endif

public enum InlineRenderer {

    /// Render an inline tree with the given base attributes.
    public static func render(
        _ inlines: [Inline],
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for inline in inlines {
            out.append(render(inline, baseAttributes: baseAttributes))
        }
        return out
    }

    private static func render(
        _ inline: Inline,
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        switch inline {
        case .text(let s):
            return NSAttributedString(string: s, attributes: baseAttributes)
        case .bold(let children):
            var attrs = baseAttributes
            attrs[.font] = applyTrait(.bold, to: baseAttributes[.font] as? PlatformFont)
            return render(children, baseAttributes: attrs)
        case .italic(let children):
            var attrs = baseAttributes
            attrs[.font] = applyTrait(.italic, to: baseAttributes[.font] as? PlatformFont)
            return render(children, baseAttributes: attrs)
        case .strikethrough(let children):
            var attrs = baseAttributes
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            return render(children, baseAttributes: attrs)
        case .code(let s):
            var attrs = baseAttributes
            let baseSize = (baseAttributes[.font] as? PlatformFont)?.pointSize ?? 14
            attrs[.font] = PlatformFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
            return NSAttributedString(string: s, attributes: attrs)
        }
    }

    private enum Trait { case bold, italic }

    private static func applyTrait(_ trait: Trait, to font: PlatformFont?) -> PlatformFont {
        let base = font ?? PlatformFont.systemFont(ofSize: 14)
        #if os(OSX)
        var traits = base.fontDescriptor.symbolicTraits
        switch trait {
        case .bold:   traits.insert(.bold)
        case .italic: traits.insert(.italic)
        }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return PlatformFont(descriptor: descriptor, size: base.pointSize) ?? base
        #else
        var traits = base.fontDescriptor.symbolicTraits
        switch trait {
        case .bold:   traits.insert(.traitBold)
        case .italic: traits.insert(.traitItalic)
        }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits) ?? base.fontDescriptor
        return PlatformFont(descriptor: descriptor, size: base.pointSize)
        #endif
    }
}
