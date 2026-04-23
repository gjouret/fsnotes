//
//  TextKit2ElementDispatchTests.swift
//  FSNotesTests
//
//  Phase 2b — proves the TK2 content-storage delegate reads the
//  `.blockModelKind` attribute written by `DocumentRenderer` and returns
//  the matching `BlockModelElement` subclass for each paragraph range.
//
//  Scope:
//    * DocumentRenderer tags every non-empty block with `.blockModelKind`.
//    * The editor's `blockModelContentDelegate` (installed in
//      `initTextStorage()`) dispatches on that tag and returns the
//      correct `BlockModelElement` subclass.
//    * Untagged ranges (tables via attachment path, blank lines) fall
//      back to nil so NSTextContentStorage uses its default paragraph
//      element — no crashes, no wrong subclass.
//
//  The tests exercise the delegate directly rather than through TK2's
//  internal enumeration. Direct exercise keeps the assertion local: if
//  the tag or the factory is wrong, this test file is the failing
//  frame, not a downstream layout test.
//

import XCTest
import AppKit
@testable import FSNotes

final class TextKit2ElementDispatchTests: XCTestCase {

    // MARK: - Helpers

    /// Returns the `(contentStorage, delegate)` pair wired to a harness
    /// editor. Fails the test if either is missing — both are Phase 2b
    /// preconditions and a missing pair means the delegate install
    /// regressed.
    private func contentStorageAndDelegate(
        _ harness: EditorHarness,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (NSTextContentStorage, BlockModelContentStorageDelegate)? {
        guard let contentStorage =
            harness.editor.textLayoutManager?.textContentManager
                as? NSTextContentStorage else {
            XCTFail(
                "Phase 2b: editor must expose NSTextContentStorage via " +
                "textLayoutManager.textContentManager. If nil, the TK2 " +
                "stack never installed.",
                file: file, line: line
            )
            return nil
        }
        guard let delegate = harness.editor.blockModelContentDelegate else {
            XCTFail(
                "Phase 2b: EditTextView.blockModelContentDelegate must " +
                "be installed by initTextStorage(). Missing means the " +
                "install step regressed.",
                file: file, line: line
            )
            return nil
        }
        return (contentStorage, delegate)
    }

    /// Fetch the element the delegate would produce for a range covering
    /// the first block in the document. Uses the block-span map so the
    /// test stays robust against trailing-newline changes.
    private func firstBlockElement(
        _ harness: EditorHarness
    ) -> NSTextParagraph? {
        guard let (storage, delegate) =
            contentStorageAndDelegate(harness) else { return nil }
        guard let span = harness.editor.documentProjection?.blockSpans.first,
              span.length > 0 else {
            XCTFail("No first-block span in projection — harness seed did not install a document.")
            return nil
        }
        return delegate.textContentStorage(
            storage,
            textParagraphWith: span
        )
    }

    // MARK: - Per-block dispatch

    func test_phase2b_paragraph_dispatchesToParagraphElement() {
        let harness = EditorHarness(markdown: "Hello paragraph.")
        defer { harness.teardown() }
        let element = firstBlockElement(harness)
        XCTAssertTrue(
            element is ParagraphElement,
            "Paragraph block should produce ParagraphElement, got " +
            "\(element.map { String(describing: type(of: $0)) } ?? "nil")"
        )
    }

    func test_phase2b_heading_dispatchesToHeadingElement() {
        let harness = EditorHarness(markdown: "# Heading text")
        defer { harness.teardown() }
        let element = firstBlockElement(harness)
        XCTAssertTrue(
            element is HeadingElement,
            "Heading block should produce HeadingElement, got " +
            "\(element.map { String(describing: type(of: $0)) } ?? "nil")"
        )
    }

    func test_phase2b_list_dispatchesToListItemElement() {
        let harness = EditorHarness(markdown: "- first item\n- second item")
        defer { harness.teardown() }
        let element = firstBlockElement(harness)
        XCTAssertTrue(
            element is ListItemElement,
            "List block should produce ListItemElement, got " +
            "\(element.map { String(describing: type(of: $0)) } ?? "nil")"
        )
    }

    func test_phase2b_blockquote_dispatchesToBlockquoteElement() {
        let harness = EditorHarness(markdown: "> quoted line")
        defer { harness.teardown() }
        let element = firstBlockElement(harness)
        XCTAssertTrue(
            element is BlockquoteElement,
            "Blockquote block should produce BlockquoteElement, got " +
            "\(element.map { String(describing: type(of: $0)) } ?? "nil")"
        )
    }

    func test_phase2b_codeBlock_dispatchesToCodeBlockElement() {
        let md = "```swift\nlet x = 1\n```"
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }
        let element = firstBlockElement(harness)
        XCTAssertTrue(
            element is CodeBlockElement,
            "Code block should produce CodeBlockElement, got " +
            "\(element.map { String(describing: type(of: $0)) } ?? "nil")"
        )
    }

    func test_phase2b_horizontalRule_dispatchesToHorizontalRuleElement() {
        let harness = EditorHarness(markdown: "---")
        defer { harness.teardown() }
        let element = firstBlockElement(harness)
        XCTAssertTrue(
            element is HorizontalRuleElement,
            "HR block should produce HorizontalRuleElement, got " +
            "\(element.map { String(describing: type(of: $0)) } ?? "nil")"
        )
    }

    // MARK: - Mixed document

    /// With several different block types in one document, every block's
    /// span must produce the matching element class. This is the path
    /// TK2 actually walks during layout.
    func test_phase2b_mixedDocument_eachBlockDispatchesCorrectly() {
        let md = [
            "# Heading",
            "",
            "First paragraph.",
            "",
            "> quoted",
            "",
            "- list item",
            "",
            "```",
            "code",
            "```",
            "",
            "---"
        ].joined(separator: "\n")

        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        guard let (storage, delegate) =
            contentStorageAndDelegate(harness) else { return }
        guard let proj = harness.editor.documentProjection else {
            return XCTFail("no projection after seed")
        }

        // Walk blocks in parallel with spans so untagged blocks (blank
        // lines, length-0 spans) are skipped — the renderer only tags
        // non-empty spans and the delegate only gets called on those.
        var expected: [(index: Int, type: Any.Type)] = []
        for (i, block) in proj.document.blocks.enumerated() {
            guard proj.blockSpans[i].length > 0 else { continue }
            switch block {
            case .paragraph: expected.append((i, ParagraphElement.self))
            case .heading: expected.append((i, HeadingElement.self))
            case .list: expected.append((i, ListItemElement.self))
            case .blockquote: expected.append((i, BlockquoteElement.self))
            case .codeBlock: expected.append((i, CodeBlockElement.self))
            case .horizontalRule: expected.append((i, HorizontalRuleElement.self))
            case .htmlBlock: expected.append((i, CodeBlockElement.self))
            case .table, .blankLine: continue // untagged, skipped
            }
        }

        XCTAssertFalse(expected.isEmpty, "mixed doc produced no tagged blocks")

        for (index, type) in expected {
            let span = proj.blockSpans[index]
            let element = delegate.textContentStorage(
                storage,
                textParagraphWith: span
            )
            XCTAssertNotNil(
                element,
                "Block #\(index) (\(type)) span=\(span) should produce an " +
                "element, got nil"
            )
            let actualType = element.map { String(describing: Swift.type(of: $0)) } ?? "nil"
            let expectedType = String(describing: type)
            XCTAssertEqual(
                actualType,
                expectedType,
                "Block #\(index) span=\(span) should produce \(expectedType), got \(actualType)"
            )
        }
    }

    // MARK: - Fallback behaviour

    /// An untagged range — for example, the inter-block separator or a
    /// splice window where the tag has not been reapplied yet — must
    /// return nil so `NSTextContentStorage` falls back to the default
    /// `NSTextParagraph`. Returning a subclass on an untagged range is
    /// the error shape that would silently corrupt layout once 2c lands.
    func test_phase2b_untaggedRange_returnsNilForDefaultFallback() {
        let harness = EditorHarness(markdown: "Hello.")
        defer { harness.teardown() }
        guard let (storage, delegate) =
            contentStorageAndDelegate(harness) else { return }
        guard let liveStorage = harness.editor.textStorage else {
            return XCTFail("no textStorage after seed")
        }

        // Strip the tag to simulate an untagged range (what the delegate
        // sees during some splice windows).
        liveStorage.removeAttribute(
            .blockModelKind,
            range: NSRange(location: 0, length: liveStorage.length)
        )

        let element = delegate.textContentStorage(
            storage,
            textParagraphWith: NSRange(location: 0, length: liveStorage.length)
        )
        XCTAssertNil(
            element,
            "Untagged range must return nil so NSTextContentStorage " +
            "falls back to NSTextParagraph. Got " +
            "\(element.map { String(describing: type(of: $0)) } ?? "nil")"
        )
    }

    /// Out-of-bounds ranges must not crash. The delegate can be called
    /// during an in-flight splice where length has shrunk; defensive
    /// clamping returns nil without touching storage.
    func test_phase2b_outOfBoundsRange_returnsNilWithoutCrashing() {
        let harness = EditorHarness(markdown: "abc")
        defer { harness.teardown() }
        guard let (storage, delegate) =
            contentStorageAndDelegate(harness) else { return }

        let tooFar = NSRange(
            location: (harness.editor.textStorage?.length ?? 0) + 100,
            length: 50
        )
        let element = delegate.textContentStorage(
            storage,
            textParagraphWith: tooFar
        )
        XCTAssertNil(element, "OOB range must return nil, got \(String(describing: element))")
    }

    // MARK: - Edit survival

    /// After a typed edit the delegate must still return the correct
    /// subclass for the edited paragraph's range. The renderer re-tags
    /// on every splice via the projection path; if it didn't, the
    /// paragraph would downgrade to default `NSTextParagraph` after the
    /// first keystroke.
    func test_phase2b_editSurvives_paragraphStaysParagraphElement() {
        let harness = EditorHarness(markdown: "Hello.")
        defer { harness.teardown() }
        harness.moveCursor(to: 5)
        harness.type("X")

        let element = firstBlockElement(harness)
        XCTAssertTrue(
            element is ParagraphElement,
            "After typing, paragraph must still dispatch to " +
            "ParagraphElement, got " +
            "\(element.map { String(describing: type(of: $0)) } ?? "nil")"
        )
    }
}
