//
//  EditorHTMLParityTests.swift
//  FSNotesTests
//
//  General-purpose WYSIWYG editor regression harness.
//
//  Idea: the editor maintains a live `Document` in
//  `documentProjection.document`. That's the same data structure
//  `CommonMarkHTMLRenderer` already knows how to turn into HTML. So for
//  any test scenario we can:
//
//      1. Build a reference Document by parsing the expected markdown
//      2. Drive the editor (fill, type, Return, toolbar toggles, …)
//      3. Render BOTH Documents to HTML and compare
//
//  HTML normalizes away everything that's rendering-implementation
//  (fonts, paragraph styles, attachment bounds, typing attributes)
//  while preserving everything that's semantically observable
//  (block structure, heading levels, list nesting, inline tree, text).
//  That's exactly the right abstraction for "did the editor's view of
//  the document match reality".
//
//  See the top comment in `CommonMarkHTMLRenderer.swift` for the
//  supported HTML subset.
//

import XCTest
import AppKit
@testable import FSNotes

class EditorHTMLParityTests: XCTestCase {

    // MARK: - Harness

    /// Make an editor hosted in a real window with a block-model note
    /// attached. Mirrors the setup used by existing full-pipeline tests
    /// in `NewLineTransitionTests.makeFullPipelineEditor`.
    private func makeEditor() -> EditTextView {
        let editor = EditTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(editor)
        editor.initTextStorage()

        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_\(UUID().uuidString).md")
        let project = Project(storage: Storage.shared(), url: URL(fileURLWithPath: NSTemporaryDirectory()))
        let note = Note(url: tmpURL, with: project)
        note.type = .Markdown
        note.content = NSMutableAttributedString(string: "")
        editor.isEditable = true
        editor.note = note
        return editor
    }

    /// Install a block-model projection for `markdown` into `editor`.
    /// Mirrors `EditTextView.fillViaBlockModel` minus the view-plumbing
    /// side effects (scroll, async table/PDF render, counter updates)
    /// that aren't needed in a unit-test environment.
    @discardableResult
    private func fill(_ editor: EditTextView, _ markdown: String) -> DocumentProjection {
        let doc = MarkdownParser.parse(markdown)
        let proj = DocumentProjection(
            document: doc,
            bodyFont: NSFont.systemFont(ofSize: 14),
            codeFont: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        )
        guard let storage = editor.textStorage else {
            XCTFail("editor has no textStorage"); return proj
        }
        editor.textStorageProcessor?.isRendering = true
        storage.setAttributedString(proj.attributed)
        editor.textStorageProcessor?.isRendering = false
        editor.documentProjection = proj
        editor.textStorageProcessor?.blockModelActive = true
        editor.note?.content = NSMutableAttributedString(string: markdown)
        editor.note?.cachedDocument = doc
        return proj
    }

    /// Render the editor's live Document to HTML and compare against
    /// the HTML of a fresh parse of `expectedMarkdown`. This is the
    /// single universal assertion for every test in this file.
    private func assertEditorMatchesMarkdown(
        _ editor: EditTextView,
        _ expectedMarkdown: String,
        _ label: String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard let live = editor.documentProjection?.document else {
            XCTFail("\(label): editor has no documentProjection", file: file, line: line)
            return
        }
        let expected = CommonMarkHTMLRenderer.render(
            MarkdownParser.parse(expectedMarkdown)
        )
        let actual = CommonMarkHTMLRenderer.render(live)

        if actual != expected {
            let liveMd = MarkdownSerializer.serialize(live)
            let msg = """
            \(label): editor HTML diverges from expected markdown HTML
            --- expected markdown ---
            \(expectedMarkdown)
            --- live markdown (from editor.document) ---
            \(liveMd)
            --- expected HTML ---
            \(expected)
            --- actual HTML ---
            \(actual)
            """
            XCTFail(msg, file: file, line: line)
        }
    }

    /// Sanity check that the editor's live Document is in sync with
    /// its own serialize → parse round-trip. If this fails, the splice
    /// path produced state that can't survive save/reload even before
    /// we compare to any expected markdown.
    private func assertLiveDocumentRoundTrips(
        _ editor: EditTextView,
        _ label: String = "",
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard let live = editor.documentProjection?.document else {
            XCTFail("\(label): editor has no documentProjection", file: file, line: line)
            return
        }
        let liveHTML = CommonMarkHTMLRenderer.render(live)
        let reparsed = MarkdownParser.parse(MarkdownSerializer.serialize(live))
        let reparsedHTML = CommonMarkHTMLRenderer.render(reparsed)
        XCTAssertEqual(
            reparsedHTML, liveHTML,
            "\(label): live Document diverges from serialize→parse round-trip",
            file: file, line: line
        )
    }

    // MARK: - Edit script DSL

    /// Declarative edit steps. Each step maps to a single editor
    /// mutation through the same entry points the real user code uses,
    /// so regressions in the dispatch path (NSTextView delegate →
    /// `handleEditViaBlockModel`, toolbar → `*ViaBlockModel`) surface
    /// here, not just pure `EditingOps` logic.
    enum EditStep {
        /// Place the cursor at `at`, zero-length selection.
        case cursorAt(Int)
        /// Select `range` in rendered storage coordinates.
        case select(NSRange)
        /// Type characters (no newlines). Goes through the same
        /// handleEditViaBlockModel path as real typing.
        case type(String)
        /// Press Return at the current selection.
        case pressReturn
        /// Backspace the character before the cursor, or delete the
        /// current selection if one exists.
        case backspace
        /// Toolbar: toggle bold on the selection.
        case toggleBold
        /// Toolbar: toggle italic on the selection.
        case toggleItalic
        /// Toolbar: set heading level at the cursor's block.
        case setHeading(level: Int)
        /// Toolbar: toggle list at the cursor's block.
        case toggleList(marker: String)
        /// Toolbar: toggle blockquote at the cursor's block.
        case toggleQuote
        /// Toolbar: insert horizontal rule after the cursor's block.
        case insertHR
        /// Toolbar: toggle todo list at the cursor's block.
        case toggleTodo
    }

    /// Run a sequence of `EditStep`s against `editor` from whatever
    /// state it's currently in.
    private func run(_ steps: [EditStep], on editor: EditTextView) {
        for step in steps {
            switch step {
            case .cursorAt(let loc):
                editor.setSelectedRange(NSRange(location: loc, length: 0))

            case .select(let r):
                editor.setSelectedRange(r)

            case .type(let s):
                // Drive the same entry point the NSTextView delegate
                // hook calls. No newlines — use .pressReturn for those.
                XCTAssertFalse(
                    s.contains("\n"),
                    "EditStep.type must not contain newlines; use .pressReturn"
                )
                _ = editor.handleEditViaBlockModel(
                    in: editor.selectedRange(),
                    replacementString: s
                )

            case .pressReturn:
                _ = editor.handleEditViaBlockModel(
                    in: editor.selectedRange(),
                    replacementString: "\n"
                )

            case .backspace:
                let sel = editor.selectedRange()
                let range: NSRange
                if sel.length > 0 {
                    range = sel
                } else if sel.location > 0 {
                    range = NSRange(location: sel.location - 1, length: 1)
                } else {
                    continue
                }
                _ = editor.handleEditViaBlockModel(
                    in: range,
                    replacementString: ""
                )

            case .toggleBold:
                _ = editor.toggleBoldViaBlockModel()
            case .toggleItalic:
                _ = editor.toggleItalicViaBlockModel()
            case .setHeading(let level):
                _ = editor.changeHeadingLevelViaBlockModel(level)
            case .toggleList(let marker):
                _ = editor.toggleListViaBlockModel(marker: marker)
            case .toggleQuote:
                _ = editor.toggleBlockquoteViaBlockModel()
            case .insertHR:
                _ = editor.insertHorizontalRuleViaBlockModel()
            case .toggleTodo:
                _ = editor.toggleTodoViaBlockModel()
            }
        }
    }

    // MARK: - Family A: fill parity
    //
    // Goal: verify that `fill()` produces a live Document that renders
    // to the same HTML as a fresh parse of the source markdown.
    // Essentially "the projection didn't corrupt the parse".

    func test_fillParity_paragraph() {
        let editor = makeEditor()
        let md = "Hello world"
        fill(editor, md)
        assertEditorMatchesMarkdown(editor, md)
        assertLiveDocumentRoundTrips(editor)
    }

    func test_fillParity_headings() {
        for level in 1...6 {
            let editor = makeEditor()
            let md = String(repeating: "#", count: level) + " Title \(level)"
            fill(editor, md)
            assertEditorMatchesMarkdown(editor, md, "H\(level)")
            assertLiveDocumentRoundTrips(editor, "H\(level)")
        }
    }

    func test_fillParity_emphasisAndCode() {
        let editor = makeEditor()
        let md = "A paragraph with **bold**, *italic*, and `code` spans."
        fill(editor, md)
        assertEditorMatchesMarkdown(editor, md)
        assertLiveDocumentRoundTrips(editor)
    }

    func test_fillParity_bulletList() {
        let editor = makeEditor()
        let md = "- First\n- Second\n- Third"
        fill(editor, md)
        assertEditorMatchesMarkdown(editor, md)
        assertLiveDocumentRoundTrips(editor)
    }

    func test_fillParity_orderedList() {
        let editor = makeEditor()
        let md = "1. Alpha\n2. Beta\n3. Gamma"
        fill(editor, md)
        assertEditorMatchesMarkdown(editor, md)
        assertLiveDocumentRoundTrips(editor)
    }

    func test_fillParity_blockquote() {
        let editor = makeEditor()
        let md = "> A quoted line"
        fill(editor, md)
        assertEditorMatchesMarkdown(editor, md)
        assertLiveDocumentRoundTrips(editor)
    }

    func test_fillParity_codeBlock() {
        let editor = makeEditor()
        let md = "```swift\nlet x = 1\nprint(x)\n```"
        fill(editor, md)
        assertEditorMatchesMarkdown(editor, md)
        assertLiveDocumentRoundTrips(editor)
    }

    func test_fillParity_mixedDocument() {
        let editor = makeEditor()
        let md = """
        # Heading

        A paragraph with **bold** text.

        - List item one
        - List item two

        > A quote

        ```
        code
        ```
        """
        fill(editor, md)
        assertEditorMatchesMarkdown(editor, md)
        assertLiveDocumentRoundTrips(editor)
    }

    // MARK: - Family B: edit-script scenarios
    //
    // Each scenario: start from some markdown, apply a list of
    // declarative edit steps through the same entry points the editor
    // uses, then assert the resulting live Document renders to the
    // same HTML as the expected markdown.
    //
    // Edit-script tests catch bugs in the live dispatch path that
    // fill-parity tests can't see: typing, Return key transitions,
    // toolbar-driven structural changes, cross-block merges.

    func test_script_typeAppendToParagraph() {
        let editor = makeEditor()
        fill(editor, "a")
        // Cursor at end of the single-char paragraph, then type.
        run([
            .cursorAt(editor.textStorage?.length ?? 0),
            .type("bcdef")
        ], on: editor)
        assertEditorMatchesMarkdown(editor, "abcdef")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_returnAfterH2_producesParagraph() {
        let editor = makeEditor()
        fill(editor, "## Bullets")
        // Cursor at end of heading content
        run([
            .cursorAt(editor.textStorage?.length ?? 0),
            .pressReturn,
            .type("body text")
        ], on: editor)
        assertEditorMatchesMarkdown(editor, "## Bullets\n\nbody text")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_returnInListAddsNewItem() {
        let editor = makeEditor()
        fill(editor, "- First")
        run([
            .cursorAt(editor.textStorage?.length ?? 0),
            .pressReturn,
            .type("Second")
        ], on: editor)
        assertEditorMatchesMarkdown(editor, "- First\n- Second")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_toggleBoldOverSelection() {
        let editor = makeEditor()
        fill(editor, "Hello world")
        // "world" = locations 6..11 in rendered paragraph text
        run([
            .select(NSRange(location: 6, length: 5)),
            .toggleBold
        ], on: editor)
        assertEditorMatchesMarkdown(editor, "Hello **world**")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_promoteParagraphToHeading() {
        let editor = makeEditor()
        fill(editor, "Some text")
        run([
            .cursorAt(0),
            .setHeading(level: 2)
        ], on: editor)
        assertEditorMatchesMarkdown(editor, "## Some text")
        assertLiveDocumentRoundTrips(editor)
    }

    /// Regression: new-blank-note scenario. `EditorViewController.createNote`
    /// seeds an empty markdown note with `"# \u{200B}"` (H1 + zero-width
    /// space) and puts the cursor at rendered position 0. Typing a title
    /// must produce a heading containing just the typed text.
    ///
    /// Bug report: "Type 'Here is a new note' into a new note. The cursor
    /// appears to the left of 'Here'. When you type the first space, the
    /// space is not rendered and all subsequent characters are swallowed."
    func test_script_typeTitleIntoFreshBlankNote() {
        let editor = makeEditor()
        fill(editor, "# ")
        run([
            .cursorAt(0),
            .type("Here is a new note")
        ], on: editor)
        assertEditorMatchesMarkdown(editor, "# Here is a new note")
        assertLiveDocumentRoundTrips(editor)
    }

    /// Same scenario, but one keystroke at a time. This is how real
    /// typing enters the editor — each character is its own splice.
    /// The bug report specifically says the FIRST SPACE after "Here"
    /// is where things break, so this must be tested per-character.
    func test_script_typeTitleIntoFreshBlankNote_perKeystroke() {
        let editor = makeEditor()
        fill(editor, "# ")
        var steps: [EditStep] = [.cursorAt(0)]
        for ch in "Here is a new note" {
            steps.append(.type(String(ch)))
        }
        run(steps, on: editor)
        assertEditorMatchesMarkdown(editor, "# Here is a new note")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_toggleListOnParagraph() {
        let editor = makeEditor()
        fill(editor, "shopping")
        run([
            .cursorAt(0),
            .toggleList(marker: "-")
        ], on: editor)
        assertEditorMatchesMarkdown(editor, "- shopping")
        assertLiveDocumentRoundTrips(editor)
    }
}
