//
//  TextKit2BaselineTests.swift
//  FSNotesTests
//
//  Phase 2a baseline — proves the switchover in
//  `EditTextView.initTextStorage()` actually flips the view onto
//  TextKit 2 at runtime. If `textLayoutManager` is still nil after
//  init, Path A failed and we must fall back to a construction-time
//  (init(coder:)) strategy before attempting any further 2a work.
//
//  Scope (per REFACTOR_PLAN.md Phase 2a):
//    * The view adopts TextKit 2 (`textLayoutManager != nil`).
//    * Plain-paragraph text round-trips through the content storage
//      and remains readable via `editor.textStorage.string` (the
//      compatibility bridge NSTextFinder walks).
//    * Editing a paragraph-only document via the block-model path
//      (`EditorHarness.type`) does not crash and leaves the new
//      layout system wired.
//
//  Out of scope — accepted 2a regressions to resurrect in 2c/2d:
//    * Custom `LayoutManager.drawBackground` visuals (bullets, HR,
//      blockquote borders). These are drawer-level regressions, not
//      correctness regressions.
//    * Rendered block attachments (code/mermaid/math/tables) may
//      render incorrectly until `NSTextLayoutFragment` overrides land.
//

import XCTest
import AppKit
@testable import FSNotes

final class TextKit2BaselineTests: XCTestCase {

    /// After `initTextStorage()`, the editor must be on TextKit 2 —
    /// `textLayoutManager` non-nil, `layoutManager` nil (AppKit returns
    /// nil for the TK1 getter once the view has adopted TK2).
    func test_phase2a_initTextStorage_adoptsTextKit2() {
        let harness = EditorHarness(markdown: "")
        defer { harness.teardown() }

        XCTAssertNotNil(
            harness.editor.textLayoutManager,
            "Phase 2a: editor must be wired to NSTextLayoutManager after" +
            " initTextStorage(). If this fails, the runtime swap in" +
            " initTextStorage() did not flip the view to TK2 — fall back" +
            " to init(coder:) interception."
        )
    }

    /// Plain-paragraph content seeded through the harness must land in
    /// the content storage and remain readable through the NSTextView
    /// compatibility `textStorage` getter (the same surface NSTextFinder
    /// walks per the Phase 2 spike).
    func test_phase2a_plainParagraph_roundTripsThroughContentStorage() {
        let md = "First paragraph.\n\nSecond paragraph with findmeinside token."
        let harness = EditorHarness(markdown: md)
        defer { harness.teardown() }

        let finderString = harness.editor.textStorage?.string ?? ""
        XCTAssertTrue(
            finderString.contains("findmeinside"),
            "Phase 2a: paragraph content seeded through the block-model" +
            " fill path must appear in textStorage.string. If this fails" +
            " NSTextContentStorage isn't bridging back through the" +
            " compatibility surface."
        )
    }

    /// Minimal repro — does a direct `storage.replaceCharacters` break
    /// TK2, or is it something higher up in the block-model edit path?
    /// This test does NOT go through `handleEditViaBlockModel`; it
    /// isolates the mutation primitive.
    func test_phase2a_directStorageMutation_preservesTextKit2() {
        let harness = EditorHarness(markdown: "Hello world.")
        defer { harness.teardown() }

        XCTAssertNotNil(harness.editor.textLayoutManager, "pre-mutation")

        guard let storage = harness.editor.textStorage else {
            return XCTFail("no textStorage")
        }
        // Phase 5a: this test intentionally performs a direct storage
        // mutation to verify TK2 infrastructure invariants. Under the
        // 5a single-write-path contract, direct writes in block-model
        // WYSIWYG mode trip a debug assertion — wrap in the legacy
        // escape hatch to signal the bypass is test-level by design.
        StorageWriteGuard.performingLegacyStorageWrite {
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: 5, length: 0), with: "X")
            storage.endEditing()
        }

        XCTAssertNotNil(
            harness.editor.textLayoutManager,
            "Direct storage.replaceCharacters must not teardown TK2."
        )
    }

    /// Narrow further: run `handleEditViaBlockModel` directly to see
    /// whether the block-model edit path is the teardown trigger.
    func test_phase2a_handleEditViaBlockModel_preservesTextKit2() {
        let harness = EditorHarness(markdown: "Hello world.")
        defer { harness.teardown() }

        XCTAssertNotNil(harness.editor.textLayoutManager, "pre-edit")

        _ = harness.editor.handleEditViaBlockModel(
            in: NSRange(location: 5, length: 0),
            replacementString: "X"
        )

        XCTAssertNotNil(
            harness.editor.textLayoutManager,
            "handleEditViaBlockModel must not teardown TK2."
        )
    }

    /// Typing into a paragraph through the harness must not crash and
    /// must leave the TK2 wiring intact. The auto-assert inside the
    /// harness's `type()` primitive covers contract invariants; this
    /// test covers only the layout-system continuity.
    func test_phase2a_typingPreservesTextKit2Wiring() {
        let harness = EditorHarness(markdown: "Hello world.")
        defer { harness.teardown() }

        XCTAssertNotNil(
            harness.editor.textLayoutManager,
            "Checkpoint A: TK2 should be alive right after seed()."
        )

        harness.moveCursor(to: 5)

        XCTAssertNotNil(
            harness.editor.textLayoutManager,
            "Checkpoint B: TK2 should be alive after moveCursor."
        )

        harness.type("X")

        XCTAssertNotNil(
            harness.editor.textLayoutManager,
            "Checkpoint C: TK2 wiring must survive a typed edit. If this" +
            " fails but A/B pass, the block-model edit path is rebuilding" +
            " the TK1 layout manager inside applyEditResultWithUndo."
        )
        XCTAssertTrue(
            (harness.editor.textStorage?.string ?? "").contains("HelloX"),
            "Phase 2a: typed character must be visible in the content" +
            " storage's bridged string."
        )
    }

    // MARK: - Storyboard-path coverage
    //
    // The first round of Phase 2a tests all created the editor via
    // `EditTextView(frame:)`, which adopts TextKit 2 on construction.
    // The real app instantiates the editor from `Main.storyboard` via
    // `init?(coder:)`, a code path those tests did NOT exercise. On
    // 2026-04-22 a first-attempt nib-path adoption (detaching the TK1
    // layout manager and calling `replaceTextContainer` with a TK2
    // container) left the view with `textStorage == nil`, crashing any
    // toolbar action that force-unwraps it (first user-visible crash:
    // `TextFormatter.init` at TextFormatter.swift:53). None of the 1123
    // pre-existing tests caught it.
    //
    // The tests below stand in for the storyboard path by constructing
    // an editor via `init(frame:textContainer:)` with a TK1 container —
    // the exact shape NSTextView has after `super.init?(coder:)`
    // decodes a nib — then running the same migration the real app
    // will run. If the editor ends with a nil `textStorage` or stays
    // on TK1, the migration has regressed.

    /// Build an EditTextView that starts life on TK1 — the state the
    /// storyboard decodes into — so we can exercise the migration
    /// without instantiating the full `Main.storyboard`.
    private func makeTextKit1Editor() -> EditTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: CGSize(width: 400, height: 400)
        )
        layoutManager.addTextContainer(container)
        return EditTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400),
            textContainer: container
        )
    }

    /// Baseline check: the TK1 stand-in editor really starts on TK1.
    /// If this fails, the rest of the storyboard tests are meaningless.
    func test_phase2a_tk1StandIn_startsOnTextKit1() {
        let editor = makeTextKit1Editor()
        XCTAssertNil(
            editor.textLayoutManager,
            "Stand-in editor built with a TK1 container should NOT have" +
            " adopted TK2 — if it has, the init(frame:textContainer:)" +
            " override is silently forcing TK2 and the storyboard" +
            " repro is invalid."
        )
        XCTAssertNotNil(
            editor.textStorage,
            "TK1 stand-in: textStorage must be live before any migration."
        )
    }

    /// The storyboard editor — after migration — must be on TK2 AND
    /// still have a live `textStorage`. Detaching the TK1 stack
    /// without a working TK2 swap leaves `textStorage` nil, which is
    /// the exact crash the 2026-04-22 first attempt shipped.
    func test_phase2a_storyboardPath_migrationAdoptsTK2_andPreservesTextStorage() {
        let oldEditor = makeTextKit1Editor()
        XCTAssertNil(oldEditor.textLayoutManager, "precondition: TK1")

        // Host the editor in a scroll view, mirroring the storyboard
        // wiring (editAreaScroll.documentView == editor).
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400)
        )
        scrollView.documentView = oldEditor

        let newEditor = EditTextView.migrateNibEditorToTextKit2(
            oldEditor: oldEditor,
            scrollView: scrollView
        )

        XCTAssertNotNil(
            newEditor.textLayoutManager,
            "After migration the editor must be on TK2."
        )
        XCTAssertNotNil(
            newEditor.textStorage,
            "After migration the editor's textStorage must still be" +
            " readable — this is the assertion that would have caught" +
            " the `TextFormatter.textStorage!` crash on 2026-04-22."
        )
        XCTAssertTrue(
            scrollView.documentView === newEditor,
            "Migration must place the new editor into the scroll view."
        )
    }

    /// The migrated editor must tolerate the exact call pattern that
    /// crashed the real app: `TextFormatter(textView:note:)` reads
    /// `textView.textStorage!` on line 53.
    func test_phase2a_storyboardPath_migratedEditor_supportsTextFormatterInit() {
        let oldEditor = makeTextKit1Editor()
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400)
        )
        scrollView.documentView = oldEditor

        let newEditor = EditTextView.migrateNibEditorToTextKit2(
            oldEditor: oldEditor,
            scrollView: scrollView
        )
        newEditor.initTextStorage()

        // Seed a note so TextFormatter has something to work on.
        newEditor.textStorage?.setAttributedString(
            NSAttributedString(string: "hello")
        )

        // The repro: TextFormatter.init reads textStorage! — if this
        // returns nil the initializer traps with SIGTRAP. The test
        // passes by reaching the assertion without crashing.
        XCTAssertNotNil(
            newEditor.textStorage,
            "Regression guard: the 2026-04-22 crash was TextFormatter" +
            " force-unwrapping a nil textStorage."
        )
    }
}
