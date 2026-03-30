//
//  InlineTagRegistry.swift
//  FSNotesCore
//
//  Data-driven registry for inline HTML tag rendering in WYSIWYG mode.
//  Adding a new tag (e.g., <sub>, <sup>) requires ONE entry here. Zero other files change.
//

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
// PlatformColor and PlatformFont are defined in FSNotesCore/SwiftHighlighter/Platform.swift

/// Describes how to render a single inline HTML tag in WYSIWYG mode.
public struct InlineTagDefinition {
    public let regex: NSRegularExpression
    public let openTagLength: Int
    public let closeTagLength: Int
    /// Attributes applied to the content range (between open and close tags).
    public let contentAttributes: [NSAttributedString.Key: Any]
    /// Optional marker attribute key for LayoutManager custom drawing (e.g., .kbdTag).
    public let markerAttributeKey: NSAttributedString.Key?

    public init(pattern: String, openTagLength: Int, closeTagLength: Int,
                contentAttributes: [NSAttributedString.Key: Any],
                markerAttributeKey: NSAttributedString.Key? = nil) {
        self.regex = try! NSRegularExpression(pattern: pattern, options: [])
        self.openTagLength = openTagLength
        self.closeTagLength = closeTagLength
        self.contentAttributes = contentAttributes
        self.markerAttributeKey = markerAttributeKey
    }
}

/// All registered inline HTML tags. ONE entry per tag. Order doesn't matter.
public func buildInlineTagDefinitions(baseFont: PlatformFont) -> [InlineTagDefinition] {
    return [
        // <u>underlined text</u>
        InlineTagDefinition(
            pattern: "<u>(.*?)</u>",
            openTagLength: 3, closeTagLength: 4,
            contentAttributes: [.underlineStyle: NSUnderlineStyle.single.rawValue]
        ),
        // <kbd>keyboard key</kbd>
        InlineTagDefinition(
            pattern: "<kbd>(.*?)</kbd>",
            openTagLength: 5, closeTagLength: 6,
            contentAttributes: [
                .font: PlatformFont.monospacedSystemFont(ofSize: baseFont.pointSize * 0.85, weight: .medium),
                .foregroundColor: PlatformColor(red: 0.333, green: 0.333, blue: 0.333, alpha: 1.0)
            ],
            markerAttributeKey: .kbdTag
        ),
        // <mark>highlighted text</mark>
        InlineTagDefinition(
            pattern: "<mark>(.*?)</mark>",
            openTagLength: 6, closeTagLength: 7,
            contentAttributes: [.backgroundColor: PlatformColor(red: 1.0, green: 0.95, blue: 0.0, alpha: 0.3)]
        ),
        // Add new tags here — one entry each:
        // <sub>, <sup>, <abbr>, <ins>, <del>, etc.
    ]
}

/// Process all inline tags in a single pass. Called from NotesTextProcessor.highlightMarkdown.
///
/// For each tag definition:
/// 1. Find all matches of the regex in the given range
/// 2. Apply contentAttributes to the content (capture group 1)
/// 3. Set the marker attribute if defined (for LayoutManager custom drawing)
/// 4. Hide the open and close tags (clear color + negative kern)
public func processInlineTags(
    definitions: [InlineTagDefinition],
    in attributedString: NSMutableAttributedString,
    string: String,
    range: NSRange,
    syntaxColor: PlatformColor,
    hideSyntax: Bool,
    hideSyntaxFunc: (NSRange) -> Void
) {
    for tag in definitions {
        tag.regex.enumerateMatches(in: string, range: range) { result, _, _ in
            guard let fullRange = result?.range,
                  let contentRange = result?.range(at: 1) else { return }

            // Apply visual attributes to content
            for (key, value) in tag.contentAttributes {
                attributedString.addAttribute(key, value: value, range: contentRange)
            }

            // Set marker attribute for LayoutManager custom drawing
            if let markerKey = tag.markerAttributeKey {
                attributedString.addAttribute(markerKey, value: true, range: contentRange)
            }

            // Hide open and close tags
            let openRange = NSRange(location: fullRange.location, length: tag.openTagLength)
            let closeRange = NSRange(location: NSMaxRange(contentRange), length: tag.closeTagLength)

            attributedString.addAttribute(.foregroundColor, value: syntaxColor, range: openRange)
            attributedString.addAttribute(.foregroundColor, value: syntaxColor, range: closeRange)

            if hideSyntax {
                hideSyntaxFunc(openRange)
                hideSyntaxFunc(closeRange)
            }
        }
    }
}
