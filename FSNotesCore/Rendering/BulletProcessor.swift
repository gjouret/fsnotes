//
//  BulletProcessor.swift
//  FSNotesCore
//
//  Phase 4 processor for unordered lists. Substitutes - / * / + with • bullet character.
//  Deferred to DispatchQueue.main.async because NSTextStorage doesn't allow replaceCharacters
//  inside the didProcessEditing delegate callback.
//

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

public struct BulletProcessor: BlockProcessor {
    public init() {}

    public func handles(_ type: MarkdownBlockType) -> Bool {
        if case .unorderedList = type { return true }
        if case .orderedList = type { return true }
        return false
    }

    public var skipSyntaxHiding: Bool { true }

    public func process(block: MarkdownBlock, textStorage: NSMutableAttributedString, flagProvider: RenderingFlagProvider) {
        guard case .unorderedList = block.type else { return }

        let syntaxRanges = block.syntaxRanges
        DispatchQueue.main.async { [weak flagProvider] in
            flagProvider?.isRendering = true
            textStorage.beginEditing()
            for syntaxRange in syntaxRanges.reversed() {
                guard syntaxRange.location < textStorage.length,
                      NSMaxRange(syntaxRange) <= textStorage.length,
                      syntaxRange.length >= 2 else { continue }
                let marker = (textStorage.string as NSString).substring(with: NSRange(location: syntaxRange.location, length: 1))
                if marker == "-" || marker == "*" || marker == "+" || marker == "\u{2022}" {
                    let bulletRange = NSRange(location: syntaxRange.location, length: 1)
                    if marker != "\u{2022}" {
                        textStorage.replaceCharacters(in: bulletRange, with: "\u{2022}")
                    }
                    let originalMarker = (marker == "\u{2022}")
                        ? (textStorage.attribute(.listBullet, at: bulletRange.location, effectiveRange: nil) as? String ?? "-")
                        : marker
                    textStorage.addAttribute(.listBullet, value: originalMarker, range: bulletRange)
                    #if os(macOS)
                    textStorage.addAttribute(.foregroundColor, value: NSColor.textColor, range: bulletRange)
                    let fontSize = CGFloat(UserDefaultsManagement.fontSize)
                    let bulletFont = NSFont.systemFont(ofSize: fontSize * 0.8)
                    textStorage.addAttribute(.font, value: bulletFont, range: bulletRange)
                    #endif
                    textStorage.removeAttribute(.kern, range: bulletRange)
                    textStorage.addAttribute(.foregroundColor, value: NSColor.textColor, range: syntaxRange)
                    textStorage.removeAttribute(.kern, range: syntaxRange)
                }
            }
            textStorage.endEditing()
            flagProvider?.isRendering = false
        }
    }
}
