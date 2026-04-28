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
            contentAttributes: [.backgroundColor: PlatformColor(red: 1.0, green: 0.9, blue: 0.0, alpha: 0.5)]
        ),
        // Add new tags here — one entry each:
        // <sub>, <sup>, <abbr>, <ins>, <del>, etc.
    ]
}

