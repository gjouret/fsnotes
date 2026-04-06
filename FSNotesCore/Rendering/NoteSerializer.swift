//
//  NoteSerializer.swift
//  FSNotesCore
//
//  Single source of truth for the attributed string ↔ markdown serialization pipeline.
//  Extracted from Note.swift and NSMutableAttributedString+.swift to make the
//  save/load transformation chain explicit, testable, and non-duplicated.
//
//  The pipeline (WYSIWYG → markdown for disk):
//    1. restoreRenderedBlocks — rendered block attachments → original markdown
//    2. unloadImagesAndFiles — image/file attachments → ![](path)
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
        let prepared = NSMutableAttributedString(attributedString: content)
        _ = prepared.restoreRenderedBlocks()
        return prepared.unloadImagesAndFiles()
    }
}
