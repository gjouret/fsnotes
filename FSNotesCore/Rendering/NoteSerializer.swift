//
//  NoteSerializer.swift
//  FSNotesCore
//
//  Single source of truth for the attributed string ↔ markdown serialization pipeline.
//  Extracted from Note.swift and NSMutableAttributedString+.swift to make the
//  save/load transformation chain explicit, testable, and non-duplicated.
//
//  The pipeline (WYSIWYG → markdown for disk):
//    1. restoreRenderedBlocks — mermaid/math attachments → original markdown
//    2. restoreBulletMarkers — • → original -/*/+ markers
//    3. unloadTasks — checkbox attachments → - [ ] / - [x]
//    4. unloadImagesAndFiles — image/file attachments → ![](path)
//
//  Each step is idempotent and order-independent within the chain.
//

import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Pure-function serialization namespace. No instance state, no I/O.
/// Every method takes input and returns output — fully testable.
public enum NoteSerializer {

    /// Full pipeline: prepare an attributed string for saving to disk as markdown.
    /// This is the ONLY place that chains the serialization steps.
    public static func prepareForSave(_ content: NSMutableAttributedString) -> NSMutableAttributedString {
        // Bullets no longer need restoration — storage always contains original markdown.
        // restoreBulletMarkers() removed: BulletProcessor no longer mutates storage.
        _ = content.restoreRenderedBlocks()
        _ = content.unloadTasks()
        _ = content.unloadImagesAndFiles()
        return content
    }

    /// Reverse bullet character substitution: • → original marker (-, *, +).
    /// Characters marked with .listBullet attribute get their original marker restored.
    public static func restoreBulletMarkers(in content: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: content.length)
        var replacements: [(NSRange, String)] = []
        content.enumerateAttribute(.listBullet, in: fullRange, options: []) { value, range, _ in
            guard let originalMarker = value as? String else { return }
            if range.location < content.length {
                let currentChar = (content.string as NSString).substring(with: NSRange(location: range.location, length: 1))
                if currentChar == "\u{2022}" {
                    replacements.append((NSRange(location: range.location, length: 1), originalMarker))
                }
            }
        }
        for (range, marker) in replacements.reversed() {
            content.replaceCharacters(in: range, with: marker)
        }
    }
}
