//
//  EditorScenario+Fixtures.swift
//  FSNotesTests
//
//  Phase 11 Slice F.1 — fixture-finding helpers shared across the
//  per-suite factories the slice is collapsing into `Given.note(...)`.
//
//  The legacy factories (`makeHarness`, `makeHarnessWithTable`, ...)
//  each ran a small post-seed search to locate the structure under
//  test (a `TableAttachment` for the subview-tables path; a
//  `TableElement` for the TK2 native path; a particular block in the
//  document). The helpers below replace those bespoke searches so the
//  test bodies can talk to the scenario through the chainable DSL
//  rather than tear-and-rebuild a tuple.
//

import XCTest
import AppKit
@testable import FSNotes

extension EditorScenario {

    // MARK: - Attachment lookups (legacy subview-tables path)

    /// First attachment of type `T` together with its storage offset.
    /// Returns `nil` when nothing of that kind exists.
    ///
    /// Used by the subview-tables test suites that need a
    /// `TableAttachment` reference. The post-WYSIWYG-migration path
    /// rarely hits this — TK2 native tables are a `TableElement`, not
    /// an attachment. See `firstTableElement(...)` for that path.
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

    // MARK: - TK2 element lookups (native-table path)

    /// First TK2 layout fragment whose `textElement` is of type `T`.
    /// Returns the element together with the storage offset of its
    /// element range start.
    ///
    /// Used by the TK2-native test suites that need to operate on a
    /// `TableElement`, `CodeBlockElement`, etc. by storage offset.
    /// Forces a layout pass before walking so the lookup sees the
    /// freshly seeded content.
    func firstFragmentElement<T: NSTextElement>(
        of type: T.Type
    ) -> (element: T, elementStart: Int)? {
        guard let tlm = editor.textLayoutManager,
              let cs = tlm.textContentManager as? NSTextContentStorage
        else { return nil }
        tlm.ensureLayout(for: tlm.documentRange)
        var found: T? = nil
        var foundStart = 0
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if let typed = fragment.textElement as? T,
               let range = typed.elementRange {
                found = typed
                foundStart = cs.offset(
                    from: cs.documentRange.location, to: range.location
                )
                return false
            }
            return true
        }
        if let f = found {
            return (element: f, elementStart: foundStart)
        }
        return nil
    }
}
