//
//  TodoListColorTests.swift
//  FSNotesTests
//
//  Bug: "in note '# FSNotes++ Bugs 3', all the text in the Todo lists
//  is white when the note is loaded. Once I make a single change in
//  the note, it renders as black text."
//
//  This test captures the contract at the pure-function layer: a
//  rendered projection for a todo-list document must carry a
//  `.foregroundColor` that resolves correctly in whatever appearance
//  the view ends up in. Concretely: it must be the dynamic
//  `NSColor.labelColor`, not a baked RGB value and not a wrong-cased
//  dark-mode variant.
//
//  The test has two layers:
//    (1) Renderer contract — `DocumentRenderer` produces the expected
//        dynamic color reference for unchecked todo text.
//    (2) Editor-fill contract — after `EditorHarness` installs the
//        projection, the storage still has that dynamic color (nothing
//        in the install path bakes it or overrides it).
//
//  If (1) fails, the bug lives in the renderer. If (1) passes and
//  (2) fails, the bug is in the fill path.
//

import XCTest
import AppKit
@testable import FSNotes

final class TodoListColorTests: XCTestCase {

    /// A todo line's inline-content characters (the letters of the
    /// first todo item) must carry `.foregroundColor = NSColor.labelColor`
    /// — a dynamic color that resolves per-view appearance at draw time.
    /// If instead it holds a statically-baked RGB NSColor, the text
    /// will draw wrong in at least one appearance.
    func test_uncheckedTodo_foregroundColorIsDynamicLabelColor() {
        let md = "- [ ] Todo text"
        let doc = MarkdownParser.parse(md)
        let proj = DocumentProjection(
            document: doc,
            bodyFont: NSFont.systemFont(ofSize: 14),
            codeFont: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        )

        let s = proj.attributed.string as NSString
        let letterRange = s.range(of: "Todo text")
        XCTAssertTrue(
            letterRange.length > 0,
            "seed todo text not found in rendered string: '\(s as String)'"
        )

        let colorAttr = proj.attributed.attribute(
            .foregroundColor,
            at: letterRange.location,
            effectiveRange: nil
        )
        XCTAssertNotNil(colorAttr, "no .foregroundColor at todo text")
        guard let color = colorAttr as? NSColor else {
            return XCTFail("foregroundColor is not an NSColor")
        }
        // NSColor.labelColor is a "catalog" dynamic color. A baked RGB
        // color has colorSpaceName `NSCalibratedRGBColorSpace` or
        // `NSDeviceRGBColorSpace`; the dynamic one reports
        // `NSNamedColorSpace` / catalog type.
        // Easiest robust assertion: it must equal `.labelColor`.
        XCTAssertEqual(
            color,
            NSColor.labelColor,
            "todo text color baked to \(color) — expected dynamic labelColor"
        )
    }

    /// After fill via EditorHarness (which mirrors
    /// `fillViaBlockModel`'s install path), the storage still has the
    /// dynamic labelColor on todo text. If the fill path bakes or
    /// overrides the color, this fails while the pure-renderer test
    /// above passes.
    func test_afterFill_todoTextStillHasDynamicLabelColor() {
        let harness = EditorHarness(markdown: "- [ ] Todo text")
        defer { harness.teardown() }
        guard let storage = harness.editor.textStorage else {
            return XCTFail("no textStorage after seed")
        }

        let s = storage.string as NSString
        let letterRange = s.range(of: "Todo text")
        XCTAssertTrue(
            letterRange.length > 0,
            "seed todo text missing after fill: '\(s as String)'"
        )

        let colorAttr = storage.attribute(
            .foregroundColor,
            at: letterRange.location,
            effectiveRange: nil
        )
        guard let color = colorAttr as? NSColor else {
            return XCTFail(
                "foregroundColor missing or not NSColor after fill"
            )
        }
        XCTAssertEqual(
            color,
            NSColor.labelColor,
            "after fill, todo text color is \(color) — expected dynamic labelColor"
        )
    }

    /// Multi-line todo lists (the shape of the bug-repro note): every
    /// todo line's text must have dynamic labelColor after fill, so
    /// the whole list draws correctly, not just the first item.
    func test_multipleTodoLines_allHaveDynamicLabelColor() {
        let md = [
            "- [ ] first todo",
            "- [ ] second todo",
            "- [x] done todo",
            "- [ ] fourth todo"
        ].joined(separator: "\n")
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }
        guard let storage = harness.editor.textStorage else {
            return XCTFail("no textStorage after seed")
        }

        let s = storage.string as NSString

        // Unchecked items: labelColor.
        for needle in ["first todo", "second todo", "fourth todo"] {
            let r = s.range(of: needle)
            XCTAssertTrue(r.length > 0, "needle \(needle) missing")
            let color = storage.attribute(
                .foregroundColor,
                at: r.location,
                effectiveRange: nil
            ) as? NSColor
            XCTAssertEqual(
                color,
                NSColor.labelColor,
                "unchecked todo '\(needle)' has \(String(describing: color)) — expected labelColor"
            )
        }

        // Checked item: the renderer uses secondaryLabelColor + strike.
        // That's a valid dynamic color too; assert just that it's
        // dynamic and not a baked fixed RGB.
        let doneRange = s.range(of: "done todo")
        XCTAssertTrue(doneRange.length > 0, "done todo missing")
        let doneColor = storage.attribute(
            .foregroundColor,
            at: doneRange.location,
            effectiveRange: nil
        ) as? NSColor
        XCTAssertEqual(
            doneColor,
            NSColor.secondaryLabelColor,
            "checked todo has \(String(describing: doneColor)) — expected secondaryLabelColor"
        )
    }
}
