//
//  EditorScenario+Fixtures.swift
//  FSNotesTests
//
//  Phase 11 Slice F.1 — fixture-finding helpers shared across the
//  per-suite factories the slice is collapsing into `Given.note(...)`.
//
//  The legacy factories (`makeHarness`, `makeHarnessWithTable`, ...)
//  each ran a small post-seed search to locate the structure under
//  test (a `TableAttachment` for the subview-tables path, a particular
//  block in the document, etc.). The helpers below replace those
//  bespoke searches so the
//  test bodies can talk to the scenario through the chainable DSL
//  rather than tear-and-rebuild a tuple.
//

import XCTest
import AppKit
@testable import FSNotes

extension EditorScenario {

    // MARK: - Attachment lookups

    /// First attachment of type `T` together with its storage offset.
    /// Returns `nil` when nothing of that kind exists.
    ///
    /// Used by the subview-tables test suites that need a
    /// `TableAttachment` reference.
    func firstAttachment<T: NSTextAttachment>(
        of type: T.Type
    ) -> (attachment: T, offset: Int)? {
        guard let storage = editor.textStorage else { return nil }
        var found: T? = nil
        var foundOffset: Int = -1
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            if let typed = value as? T {
                found = typed
                foundOffset = range.location
                stop.pointee = true
            }
        }
        if let f = found, foundOffset >= 0 {
            return (attachment: f, offset: foundOffset)
        }
        return nil
    }

    // MARK: - Document block extraction

    /// Extract the `Block.table` at `index` from the live document.
    /// Returns nil when the block at that index isn't a table or when
    /// the document/projection isn't available.
    func tableBlock(
        at index: Int
    ) -> (
        header: [TableCell],
        alignments: [TableAlignment],
        rows: [[TableCell]]
    )? {
        guard let doc = editor.documentProjection?.document,
              index < doc.blocks.count,
              case .table(let h, let a, let r, _) = doc.blocks[index]
        else { return nil }
        return (h, a, r)
    }

    /// Index of the first `.table` block in the live document, or nil.
    func firstTableBlockIndex() -> Int? {
        guard let doc = editor.documentProjection?.document else {
            return nil
        }
        for (i, b) in doc.blocks.enumerated() {
            if case .table = b { return i }
        }
        return nil
    }
}
