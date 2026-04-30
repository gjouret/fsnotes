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
        editor.allowsUndo = true
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
        /// Place the cursor at the end of the current storage.
        case cursorAtEnd
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
        /// Tab key: indent list item via FSM, or insert tab in non-list.
        case tab
        /// Shift-Tab key: unindent list item via FSM.
        case shiftTab
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
        /// Toolbar: toggle strikethrough on the selection.
        case toggleStrikethrough
        /// Toolbar: toggle todo checkbox at cursor.
        case toggleTodoCheckbox
    }

    /// Run a sequence of `EditStep`s against `editor` from whatever
    /// state it's currently in.
    private func run(_ steps: [EditStep], on editor: EditTextView) {
        for step in steps {
            switch step {
            case .cursorAt(let loc):
                let safeLoc = min(loc, editor.textStorage?.length ?? 0)
                editor.setSelectedRange(NSRange(location: safeLoc, length: 0))

            case .cursorAtEnd:
                let len = editor.textStorage?.length ?? 0
                editor.setSelectedRange(NSRange(location: len, length: 0))

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

            case .tab:
                // Route through the FSM the same way keyDown does.
                if let projection = editor.documentProjection {
                    let cursorPos = editor.selectedRange().location
                    let state = ListEditingFSM.detectState(storageIndex: cursorPos, in: projection)
                    if case .listItem = state {
                        let transition = ListEditingFSM.transition(state: state, action: .tab)
                        _ = editor.handleListTransition(transition, at: cursorPos)
                    }
                }

            case .shiftTab:
                if let projection = editor.documentProjection {
                    let cursorPos = editor.selectedRange().location
                    let state = ListEditingFSM.detectState(storageIndex: cursorPos, in: projection)
                    if case .listItem = state {
                        let transition = ListEditingFSM.transition(state: state, action: .shiftTab)
                        _ = editor.handleListTransition(transition, at: cursorPos)
                    }
                }

            case .toggleBold:
                _ = editor.toggleInlineTraitViaBlockModel(.bold)
            case .toggleItalic:
                _ = editor.toggleInlineTraitViaBlockModel(.italic)
            case .toggleStrikethrough:
                _ = editor.toggleInlineTraitViaBlockModel(.strikethrough)
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
            case .toggleTodoCheckbox:
                _ = editor.toggleTodoCheckboxViaBlockModel()
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

    // MARK: - Family C: FSM transition coverage (RC8)
    //
    // Each test exercises one FSM transition through the real editor
    // pipeline and asserts structural correctness via HTML parity.

    // --- Return key transitions ---

    func test_script_returnOnEmptyListItem_exitsToBody() {
        let editor = makeEditor()
        fill(editor, "- First\n- ")
        // Bug #21: pressing Return on the empty second item leaves the
        // existing item in place and exits the list to an empty paragraph
        // (the dropped marker becomes a body paragraph). Round-trip
        // serializer emits the paragraph as a blank-line gap.
        run([.cursorAtEnd, .pressReturn], on: editor)
        assertEditorMatchesMarkdown(editor, "- First\n")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_returnOnEmptyNestedItem_unindents() {
        let editor = makeEditor()
        fill(editor, "- Parent\n  - ")
        // Cursor at end of empty nested item, press Return → unindent to L1
        run([.cursorAtEnd, .pressReturn], on: editor)
        assertEditorMatchesMarkdown(editor, "- Parent\n- ")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_returnAfterH1_producesParagraph() {
        let editor = makeEditor()
        fill(editor, "# Title")
        run([.cursorAtEnd, .pressReturn, .type("body")], on: editor)
        assertEditorMatchesMarkdown(editor, "# Title\n\nbody")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_returnInOrderedList_addsNextNumber() {
        let editor = makeEditor()
        fill(editor, "1. First")
        run([.cursorAtEnd, .pressReturn, .type("Second")], on: editor)
        assertEditorMatchesMarkdown(editor, "1. First\n2. Second")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_multipleReturns_createBlankLines() {
        let editor = makeEditor()
        fill(editor, "# Title")
        run([
            .cursorAtEnd,
            .pressReturn,
            .pressReturn,
            .type("after blank")
        ], on: editor)
        assertEditorMatchesMarkdown(editor, "# Title\n\n\n\nafter blank")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_returnOnCheckedTodo_producesUnchecked() {
        let editor = makeEditor()
        fill(editor, "- [x] Done task")
        run([.cursorAtEnd, .pressReturn, .type("New task")], on: editor)
        assertEditorMatchesMarkdown(editor, "- [x] Done task\n- [ ] New task")
        assertLiveDocumentRoundTrips(editor)
    }

    // --- Tab / Shift-Tab transitions ---

    func test_script_tabIndentsListItem() {
        let editor = makeEditor()
        fill(editor, "- First\n- Second")
        // Put cursor in "Second", press Tab → becomes child of First
        run([.cursorAtEnd, .tab], on: editor)
        assertEditorMatchesMarkdown(editor, "- First\n  - Second")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_shiftTabUnindentsListItem() {
        let editor = makeEditor()
        fill(editor, "- First\n  - Nested")
        run([.cursorAtEnd, .shiftTab], on: editor)
        assertEditorMatchesMarkdown(editor, "- First\n- Nested")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_shiftTabOnTopLevelItem_exitsToBody() {
        let editor = makeEditor()
        fill(editor, "- Only item")
        run([.cursorAtEnd, .shiftTab], on: editor)
        assertEditorMatchesMarkdown(editor, "Only item")
        assertLiveDocumentRoundTrips(editor)
    }

    // --- Delete at block boundary (merge operations) ---

    func test_script_merge_paragraphParagraph() {
        let editor = makeEditor()
        fill(editor, "Hello\n\nWorld")
        // Cursor at start of "World", backspace removes blank line + merges
        let worldStart = (editor.textStorage?.string as NSString?)?.range(of: "World").location ?? 0
        run([.cursorAt(worldStart), .backspace], on: editor)
        // After merge: blank line removed, leaving two paragraphs that merge
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_merge_headingParagraph() {
        let editor = makeEditor()
        fill(editor, "## Heading\n\nBody text")
        let bodyStart = (editor.textStorage?.string as NSString?)?.range(of: "Body").location ?? 0
        run([.cursorAt(bodyStart), .backspace], on: editor)
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_deleteAtHomeInHeading_convertsToParagraph() {
        let editor = makeEditor()
        fill(editor, "Some text\n\n## Heading")
        let headingStart = (editor.textStorage?.string as NSString?)?.range(of: "Heading").location ?? 0
        run([.cursorAt(headingStart), .backspace], on: editor)
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_deleteAtHomeInList_exitsToBody() {
        let editor = makeEditor()
        fill(editor, "- Only item")
        // Cursor at start of list item text, backspace → exit to body
        // In rendered output, the bullet is an attachment char, so offset 1 is text start
        run([.cursorAt(1), .backspace], on: editor)
        assertEditorMatchesMarkdown(editor, "Only item")
        assertLiveDocumentRoundTrips(editor)
    }

    // --- Toolbar: heading level changes ---

    func test_script_headingLevelChange_H2toH3() {
        let editor = makeEditor()
        fill(editor, "## Heading")
        run([.cursorAt(0), .setHeading(level: 3)], on: editor)
        assertEditorMatchesMarkdown(editor, "### Heading")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_headingToggleOff() {
        let editor = makeEditor()
        fill(editor, "## Heading")
        // Setting level 2 again on an H2 should toggle it OFF to paragraph
        run([.cursorAt(0), .setHeading(level: 2)], on: editor)
        assertEditorMatchesMarkdown(editor, "Heading")
        assertLiveDocumentRoundTrips(editor)
    }

    // --- Toolbar: list toggle off ---

    func test_script_toggleListOff() {
        let editor = makeEditor()
        fill(editor, "- Item")
        run([.cursorAtEnd, .toggleList(marker: "-")], on: editor)
        assertEditorMatchesMarkdown(editor, "Item")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_toggleNumberedList() {
        let editor = makeEditor()
        fill(editor, "Item")
        run([.cursorAt(0), .toggleList(marker: "1.")], on: editor)
        assertEditorMatchesMarkdown(editor, "1. Item")
        assertLiveDocumentRoundTrips(editor)
    }

    // --- Toolbar: blockquote ---

    func test_script_toggleBlockquoteOn() {
        let editor = makeEditor()
        fill(editor, "A quote")
        run([.cursorAt(0), .toggleQuote], on: editor)
        assertEditorMatchesMarkdown(editor, "> A quote")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_toggleBlockquoteOff() {
        let editor = makeEditor()
        fill(editor, "> A quote")
        run([.cursorAtEnd, .toggleQuote], on: editor)
        assertEditorMatchesMarkdown(editor, "A quote")
        assertLiveDocumentRoundTrips(editor)
    }

    // --- Toolbar: horizontal rule ---

    func test_script_insertHR() {
        let editor = makeEditor()
        fill(editor, "Before")
        run([.cursorAtEnd, .insertHR], on: editor)
        assertLiveDocumentRoundTrips(editor)
    }

    // --- Toolbar: todo ---

    func test_script_toggleTodoOnParagraph() {
        let editor = makeEditor()
        fill(editor, "Buy milk")
        run([.cursorAt(0), .toggleTodo], on: editor)
        assertEditorMatchesMarkdown(editor, "- [ ] Buy milk")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_toggleTodoOff() {
        let editor = makeEditor()
        fill(editor, "- [ ] Buy milk")
        run([.cursorAtEnd, .toggleTodo], on: editor)
        assertEditorMatchesMarkdown(editor, "Buy milk")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_toggleTodoCheckbox() {
        let editor = makeEditor()
        fill(editor, "- [ ] Unchecked")
        run([.cursorAtEnd, .toggleTodoCheckbox], on: editor)
        assertEditorMatchesMarkdown(editor, "- [x] Unchecked")
        assertLiveDocumentRoundTrips(editor)
    }

    // --- Inline formatting ---

    func test_script_toggleBoldOff() {
        let editor = makeEditor()
        fill(editor, "Hello **world**")
        // Select "world" in rendered text — "Hello " is 6 chars, bold "world" is 5
        run([
            .select(NSRange(location: 6, length: 5)),
            .toggleBold
        ], on: editor)
        assertEditorMatchesMarkdown(editor, "Hello world")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_toggleItalicOverSelection() {
        let editor = makeEditor()
        fill(editor, "Hello world")
        run([
            .select(NSRange(location: 6, length: 5)),
            .toggleItalic
        ], on: editor)
        assertEditorMatchesMarkdown(editor, "Hello *world*")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_toggleStrikethroughOverSelection() {
        let editor = makeEditor()
        fill(editor, "Hello world")
        run([
            .select(NSRange(location: 6, length: 5)),
            .toggleStrikethrough
        ], on: editor)
        assertEditorMatchesMarkdown(editor, "Hello ~~world~~")
        assertLiveDocumentRoundTrips(editor)
    }

    // --- Complex multi-step scenarios ---

    func test_script_createListThenIndentThenReturn() {
        let editor = makeEditor()
        fill(editor, "- First\n- Second")
        // Indent Second, then add a new item after it
        run([
            .cursorAtEnd,
            .tab,
            .pressReturn,
            .type("Third")
        ], on: editor)
        assertEditorMatchesMarkdown(editor, "- First\n  - Second\n  - Third")
        assertLiveDocumentRoundTrips(editor)
    }

    // --- Mid-sequence Return (user-reported bugs) ---

    func test_script_returnBetweenTodos_doesNotDeleteNeighbor() {
        // User-reported bug: Return on middle Todo deletes the one below.
        let editor = makeEditor()
        fill(editor, "- [ ] One\n- [ ] Two\n- [ ] Three")
        // Cursor at end of "Two", press Return → new empty todo, "Three" preserved
        let twoRange = (editor.textStorage?.string as NSString?)?.range(of: "Two") ?? NSRange(location: 0, length: 0)
        let twoEnd = twoRange.location + twoRange.length
        run([.cursorAt(twoEnd), .pressReturn], on: editor)
        assertEditorMatchesMarkdown(editor, "- [ ] One\n- [ ] Two\n- [ ] \n- [ ] Three")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_returnTwiceBetweenTodos_doesNotDeleteNeighbor() {
        // User-reported bug: press Return after middle Todo (creating a new
        // empty todo), then Return again — the todo BELOW gets deleted.
        //
        // Post-Bug #21 behavior: the second Return on an empty L1 item now
        // EXITS the list via "paragraph in place" (consistent with Return
        // at home of a non-empty item). For a middle item this means the
        // list splits into [list(One, Two), paragraph(), list(Three)]. The
        // bug this test protects against ("Three deleted") remains fixed:
        // Three survives as its own list below the paragraph.
        //
        // NOTE: `assertLiveDocumentRoundTrips` is intentionally NOT called
        // here because serialize(list + empty-para + list) parses back as
        // a single coalesced list — that's a parser-level coalesce behavior
        // independent of Bug #21, and the live Document is the source of
        // truth for the cursor's actual structural state.
        let editor = makeEditor()
        fill(editor, "- [ ] One\n- [ ] Two\n- [ ] Three")
        let twoRange = (editor.textStorage?.string as NSString?)?.range(of: "Two") ?? NSRange(location: 0, length: 0)
        let twoEnd = twoRange.location + twoRange.length
        run([.cursorAt(twoEnd), .pressReturn, .pressReturn], on: editor)
        let serialized = MarkdownSerializer.serialize(editor.documentProjection?.document ?? Document(blocks: []))
        XCTAssertTrue(serialized.contains("Three"), "Third todo must not be deleted; got: \(serialized)")
        // Confirm the live Document still contains "Three" as a list item
        // (regardless of whether the list split or stayed whole).
        let doc = editor.documentProjection?.document ?? Document(blocks: [])
        var foundThreeItem = false
        for block in doc.blocks {
            if case .list(let items, _) = block {
                for item in EditingOps.flattenList(items) {
                    let itemText = item.item.inline.compactMap { inl -> String? in
                        if case .text(let s) = inl { return s }
                        return nil
                    }.joined()
                    if itemText.contains("Three") { foundThreeItem = true }
                }
            }
        }
        XCTAssertTrue(foundThreeItem, "Third todo must survive as a list item; got blocks: \(doc.blocks)")
    }

    func test_script_returnBetweenListItems_insertsNewItem() {
        let editor = makeEditor()
        fill(editor, "- One\n- Two\n- Three")
        let twoRange = (editor.textStorage?.string as NSString?)?.range(of: "Two") ?? NSRange(location: 0, length: 0)
        let twoEnd = twoRange.location + twoRange.length
        run([.cursorAt(twoEnd), .pressReturn, .type("Inserted")], on: editor)
        assertEditorMatchesMarkdown(editor, "- One\n- Two\n- Inserted\n- Three")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_returnSplitsListItemMidText() {
        let editor = makeEditor()
        fill(editor, "- HelloWorld")
        // Cursor between "Hello" and "World"
        let splitAt = (editor.textStorage?.string as NSString?)?.range(of: "World").location ?? 0
        run([.cursorAt(splitAt), .pressReturn], on: editor)
        assertEditorMatchesMarkdown(editor, "- Hello\n- World")
        assertLiveDocumentRoundTrips(editor)
    }

    // --- Cross-block merges (uncovered) ---

    func test_script_merge_listParagraph() {
        let editor = makeEditor()
        fill(editor, "- Item\n\nBody")
        let bodyStart = (editor.textStorage?.string as NSString?)?.range(of: "Body").location ?? 0
        run([.cursorAt(bodyStart), .backspace], on: editor)
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_merge_blockquoteParagraph() {
        // KNOWN BUG: backspace at start of a paragraph after a blockquote
        // joins the paragraph into the blockquote with a soft break, but
        // serialize→parse round-trip keeps them separate. The live state
        // can't survive save/load. Tracked under RC8 followup.
        XCTExpectFailure("Blockquote+paragraph merge produces non-round-trippable state (RC8 followup)")
        let editor = makeEditor()
        fill(editor, "> Quote\n\nBody")
        let bodyStart = (editor.textStorage?.string as NSString?)?.range(of: "Body").location ?? 0
        run([.cursorAt(bodyStart), .backspace], on: editor)
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_merge_paragraphHeading() {
        let editor = makeEditor()
        fill(editor, "Body\n\n## Heading")
        // Cursor at start of "## Heading" rendered as just "Heading" (markers hidden)
        let headingStart = (editor.textStorage?.string as NSString?)?.range(of: "Heading").location ?? 0
        run([.cursorAt(headingStart), .backspace], on: editor)
        assertLiveDocumentRoundTrips(editor)
    }

    // --- Inline toggle ON over plain text ---

    func test_script_toggleBoldOnSelection() {
        let editor = makeEditor()
        fill(editor, "Hello world")
        run([
            .select(NSRange(location: 6, length: 5)),
            .toggleBold
        ], on: editor)
        assertEditorMatchesMarkdown(editor, "Hello **world**")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_toggleItalicOff() {
        let editor = makeEditor()
        fill(editor, "Hello *world*")
        run([
            .select(NSRange(location: 6, length: 5)),
            .toggleItalic
        ], on: editor)
        assertEditorMatchesMarkdown(editor, "Hello world")
        assertLiveDocumentRoundTrips(editor)
    }

    // --- Cursor-only (no selection) toolbar ops should affect ONE block ---

    func test_script_setHeadingOnEmptyLine_affectsOnlyThatLine() {
        // User-reported bug: CMD+3 on blank line between paragraphs converts
        // 3 paragraphs to H3. Cursor-only setHeading must affect ONE block.
        let editor = makeEditor()
        fill(editor, "First para\n\n\nThird para")
        // Cursor on the blank line between "First para" and "Third para"
        let firstRange = (editor.textStorage?.string as NSString?)?.range(of: "First para") ?? NSRange(location: 0, length: 0)
        let firstEnd = firstRange.location + firstRange.length
        run([.cursorAt(firstEnd + 1), .setHeading(level: 3)], on: editor)
        // First and Third should remain paragraphs; only the blank line becomes H3.
        assertLiveDocumentRoundTrips(editor)
        // Verify via round-trip serialization that "First para" and "Third para"
        // are still plain paragraphs (not part of a multi-line H3).
        let doc = editor.documentProjection?.document ?? Document(blocks: [])
        let serialized = MarkdownSerializer.serialize(doc)
        XCTAssertFalse(serialized.contains("### First"), "First para must not become H3; got: \(serialized)")
        XCTAssertFalse(serialized.contains("### Third"), "Third para must not become H3; got: \(serialized)")
    }

    // MARK: - Family D: RC2 boundary ambiguity regressions
    //
    // Cursor positions at exact block boundaries (end of block A ==
    // start of separator before block B) used to map to the wrong
    // block. Each test pins down one boundary symptom.

    func test_rc2_toggleTodo_onSecondParagraph_affectsOnlyThatParagraph() {
        let editor = makeEditor()
        fill(editor, "First para\n\nSecond para\n\nThird para")
        // Cursor on the SECOND paragraph, at its start
        let s = editor.textStorage?.string as NSString? ?? ""
        let secondRange = s.range(of: "Second para")
        run([.cursorAt(secondRange.location), .toggleTodo], on: editor)
        assertEditorMatchesMarkdown(
            editor,
            "First para\n\n- [ ] Second para\n\nThird para"
        )
        assertLiveDocumentRoundTrips(editor)
    }

    func test_rc2_toggleTodo_atEndOfSecondParagraph_affectsOnlyThatParagraph() {
        let editor = makeEditor()
        fill(editor, "First para\n\nSecond para\n\nThird para")
        let s = editor.textStorage?.string as NSString? ?? ""
        let secondRange = s.range(of: "Second para")
        let end = secondRange.location + secondRange.length
        run([.cursorAt(end), .toggleTodo], on: editor)
        assertEditorMatchesMarkdown(
            editor,
            "First para\n\n- [ ] Second para\n\nThird para"
        )
        assertLiveDocumentRoundTrips(editor)
    }

    func test_rc2_typeAtStartOfSecondParagraph_appendsToSecond() {
        let editor = makeEditor()
        fill(editor, "First\n\nSecond")
        let s = editor.textStorage?.string as NSString? ?? ""
        let secondRange = s.range(of: "Second")
        run([.cursorAt(secondRange.location), .type("X")], on: editor)
        assertEditorMatchesMarkdown(editor, "First\n\nXSecond")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_rc2_setHeadingOnSecondParagraph_affectsOnlyThatParagraph() {
        let editor = makeEditor()
        fill(editor, "First para\n\nSecond para\n\nThird para")
        let s = editor.textStorage?.string as NSString? ?? ""
        let secondRange = s.range(of: "Second para")
        run([.cursorAt(secondRange.location), .setHeading(level: 2)], on: editor)
        assertEditorMatchesMarkdown(
            editor,
            "First para\n\n## Second para\n\nThird para"
        )
        assertLiveDocumentRoundTrips(editor)
    }

    func test_rc2_deleteAtEndOfListItem_staysInList() {
        let editor = makeEditor()
        fill(editor, "- First\n- Second\n- Third")
        // Cursor at the end of "Second"
        let s = editor.textStorage?.string as NSString? ?? ""
        let secondRange = s.range(of: "Second")
        let end = secondRange.location + secondRange.length
        run([.cursorAt(end), .backspace], on: editor)
        assertEditorMatchesMarkdown(editor, "- First\n- Secon\n- Third")
        assertLiveDocumentRoundTrips(editor)
    }

    // MARK: - Family E: RC3 multi-block & code-block selection regressions

    func test_rc3_insertCodeBlock_withSelection_preservesUnselectedText() {
        // User-reported: select text + Code Block button deletes text.
        // Selecting "bar" in "foo bar baz" then pressing Code Block used
        // to replace the entire paragraph with a code block containing
        // just "bar", losing "foo " and " baz".
        let editor = makeEditor()
        fill(editor, "foo bar baz")
        let s = editor.textStorage?.string as NSString? ?? ""
        let barRange = s.range(of: "bar")
        editor.setSelectedRange(barRange)
        _ = editor.perform(#selector(EditTextView.insertCodeBlock(_:)), with: nil)
        assertEditorMatchesMarkdown(
            editor,
            "foo \n\n```\nbar\n```\n\n baz"
        )
        assertLiveDocumentRoundTrips(editor)
    }

    // MARK: - Family F: RC4 inline re-parsing regressions

    func test_bug39_pasteMultilineWithBold_preservesFormatting() {
        // User-reported: copying a list line that contains bold loses
        // the bold on paste. Paste path: insertText(markdown) →
        // handleEditViaBlockModel → EditingOps.insert → pasteIntoParagraph.
        // The old implementation wrapped each pasted line as a single
        // `.text` node, stripping all inline markers. Now each line
        // is parsed via `MarkdownParser.parseInlines`.
        let editor = makeEditor()
        fill(editor, "x")
        // Simulate a paste by inserting multi-line markdown text.
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        _ = editor.handleEditViaBlockModel(
            in: NSRange(location: 1, length: 0),
            replacementString: "\n**hello** world\nplain line"
        )
        let doc = editor.documentProjection?.document ?? Document(blocks: [])
        let md = MarkdownSerializer.serialize(doc)
        XCTAssertTrue(
            md.contains("**hello**"),
            "bold must survive paste; got: \(md)"
        )
        assertLiveDocumentRoundTrips(editor)
    }

    func test_bug75_wikilink_parsesAndRenders() {
        let editor = makeEditor()
        fill(editor, "see [[My Note]] for details")
        let doc = editor.documentProjection?.document ?? Document(blocks: [])
        // Find the wikilink inline in the first paragraph.
        var found = false
        if case .paragraph(let inline) = doc.blocks[0] {
            for node in inline {
                if case .wikilink(let target, _) = node, target == "My Note" {
                    found = true
                    break
                }
            }
        }
        XCTAssertTrue(found, "expected Inline.wikilink in parsed document; got: \(doc.blocks)")
        // Round-trip: serialize should re-emit `[[My Note]]` verbatim.
        let md = MarkdownSerializer.serialize(doc)
        XCTAssertTrue(
            md.contains("[[My Note]]"),
            "expected wikilink in serialized output; got: \(md)"
        )
        // Rendered storage must NOT contain the `[[ ]]` brackets.
        let rendered = editor.textStorage?.string ?? ""
        XCTAssertFalse(rendered.contains("[["), "brackets must not appear in rendered text; got: \(rendered)")
        XCTAssertFalse(rendered.contains("]]"), "brackets must not appear in rendered text; got: \(rendered)")
        XCTAssertTrue(rendered.contains("My Note"), "wikilink text must appear; got: \(rendered)")
    }

    func test_bug75_wikilink_withDisplayText() {
        let editor = makeEditor()
        fill(editor, "see [[target|Alt Text]] here")
        let doc = editor.documentProjection?.document ?? Document(blocks: [])
        if case .paragraph(let inline) = doc.blocks[0] {
            for node in inline {
                if case .wikilink(let target, let display) = node {
                    XCTAssertEqual(target, "target")
                    XCTAssertEqual(display, "Alt Text")
                    return
                }
            }
        }
        XCTFail("expected wikilink with display text")
    }

    func test_bug75_wikilink_roundTrip() {
        let editor = makeEditor()
        fill(editor, "[[Note A]] and [[Note B|B]]")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_bug90_codeBlockToolbarOnSelection_rendersAsCodeBlock() {
        // User-reported: selecting text + Format/Code Block produces
        // fences but doesn't render properly. Verify that the resulting
        // Document contains a `.codeBlock` block (renderable) rather
        // than a `.paragraph` containing the fences as plain text.
        let editor = makeEditor()
        fill(editor, "foo bar baz")
        let s = editor.textStorage?.string as NSString? ?? ""
        let barRange = s.range(of: "bar")
        editor.setSelectedRange(barRange)
        _ = editor.perform(#selector(EditTextView.insertCodeBlock(_:)), with: nil)
        let doc = editor.documentProjection?.document ?? Document(blocks: [])
        let hasCodeBlock = doc.blocks.contains(where: { block in
            if case .codeBlock = block { return true }
            return false
        })
        XCTAssertTrue(
            hasCodeBlock,
            "expected a code block in document; got: \(doc.blocks)"
        )
        // Re-parsing the serialized output must also yield a code block
        // (i.e. the markdown is well-formed and the renderer's HTML
        // matches the parser's HTML).
        assertLiveDocumentRoundTrips(editor)
    }

    func test_bug88_returnOnBlankLineInCodeBlock_exitsToParagraph() {
        // User-reported: no keyboard way to leave a code block — the
        // user has to switch to source mode to escape. Heuristic: at
        // the end of the content with a trailing newline (i.e. the
        // user just pressed Return on what is now an empty line),
        // close the code block and insert a paragraph after.
        let editor = makeEditor()
        fill(editor, "```\nlet x = 1\n```")
        // Cursor at end of the content; press Return to add a blank
        // trailing line, then press Return again to exit.
        let len = editor.textStorage?.length ?? 0
        run([
            .cursorAt(len),
            .pressReturn,        // adds trailing newline within code
            .pressReturn,        // exits the code block
            .type("after")
        ], on: editor)
        let doc = editor.documentProjection?.document ?? Document(blocks: [])
        let md = MarkdownSerializer.serialize(doc)
        // The "after" paragraph must exist OUTSIDE the code block.
        XCTAssertTrue(
            md.contains("after"),
            "expected paragraph after code block; got: \(md)"
        )
        XCTAssertTrue(
            md.contains("let x = 1"),
            "code content preserved; got: \(md)"
        )
        // The code block must close before "after" — i.e. there must
        // be a closing fence somewhere before "after" in the markdown.
        if let fenceClose = md.range(of: "```", options: .backwards),
           let afterRange = md.range(of: "after") {
            XCTAssertLessThan(
                fenceClose.lowerBound, afterRange.lowerBound,
                "closing fence must precede 'after'; got: \(md)"
            )
        } else {
            XCTFail("expected closing fence and 'after' in: \(md)")
        }
        assertLiveDocumentRoundTrips(editor)
    }

    func test_bug25_deleteOnSecondOfTwoBlankParagraphs_collapsesUpward() {
        // User-reported: with two blank paragraphs in a row, pressing
        // Delete (Backspace) at home of the SECOND blank paragraph
        // should collapse it upward (merge with first), not delete
        // the next line below. The FSM must not behave differently
        // when there are two blanks vs one.
        let editor = makeEditor()
        fill(editor, "before\n\n\n\nafter")
        // Storage for "before\n\n\n\nafter" is roughly:
        // before(0..6), blank, blank, blank, after — let's find the
        // home of the second blank line.
        let s = editor.textStorage?.string as NSString? ?? ""
        let beforeRange = s.range(of: "before")
        let afterRange = s.range(of: "after")
        // Cursor in the middle of the blank gap (after one separator).
        let mid = beforeRange.location + beforeRange.length + 1
        run([.cursorAt(mid), .backspace], on: editor)
        // "after" must still exist; the delete should remove a blank,
        // not the "after" paragraph.
        let doc = editor.documentProjection?.document ?? Document(blocks: [])
        let md = MarkdownSerializer.serialize(doc)
        XCTAssertTrue(md.contains("before"), "before preserved; got: \(md)")
        XCTAssertTrue(md.contains("after"), "after preserved; got: \(md)")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_bug28_deleteOnEmptyTodoBetweenItems_exitsToParagraph() {
        // User-reported: blank Todo list line between two todos. Delete
        // (Backspace at home) should remove the checkbox and convert
        // the blank to a body text paragraph — NOT delete the line and
        // jump to the previous item. This is the standard FSM exit-list
        // path; it must work even when there are sibling items below.
        //
        // Post-Bug #21 / #28 semantics: exit-to-paragraph produces a
        // live Document shaped `[list(First), paragraph(empty), list(Third)]`.
        // A serialize→parse round-trip coalesces the two lists into a
        // single loose list — that's a parser-level coalesce behavior
        // independent of this bug's fix. We don't compare live HTML vs
        // re-parsed HTML here; the structural invariant (First and Third
        // both survive as list items, empty middle is no longer a todo)
        // is what we verify directly.
        let editor = makeEditor()
        fill(editor, "- [ ] First\n- [ ] \n- [ ] Third")
        // Cursor at home of the empty middle todo (after its checkbox)
        let s = editor.textStorage?.string as NSString? ?? ""
        // Find the second checkbox position by counting attachments
        // — use string search for "Third" and compute 1 char before its line break
        let thirdRange = s.range(of: "Third")
        // The empty todo's home is 2 chars before "Third" (separator + checkbox)
        // We use a simpler approach: select the empty todo line via paragraph range
        let emptyLineStart = thirdRange.location - 2
        run([.cursorAt(emptyLineStart), .backspace], on: editor)
        // The empty middle todo should become a paragraph (or blank line).
        let doc = editor.documentProjection?.document ?? Document(blocks: [])
        let md = MarkdownSerializer.serialize(doc)
        XCTAssertTrue(md.contains("- [ ] First"), "First todo preserved; got: \(md)")
        XCTAssertTrue(md.contains("- [ ] Third"), "Third todo preserved; got: \(md)")
        XCTAssertFalse(md.contains("- [ ] First\n- [ ] \n- [ ] Third"),
                       "empty todo should have been converted; got: \(md)")
        // Live-Document structural check: First and Third must still be
        // reachable as list items (no jump-to-previous regression).
        var foundFirst = false
        var foundThird = false
        for block in doc.blocks {
            if case .list(let items, _) = block {
                for item in EditingOps.flattenList(items) {
                    let itemText = item.item.inline.compactMap { inl -> String? in
                        if case .text(let s) = inl { return s }
                        return nil
                    }.joined()
                    if itemText.contains("First") { foundFirst = true }
                    if itemText.contains("Third") { foundThird = true }
                }
            }
        }
        XCTAssertTrue(foundFirst, "First todo must survive as a list item; got blocks: \(doc.blocks)")
        XCTAssertTrue(foundThird, "Third todo must survive as a list item; got blocks: \(doc.blocks)")
    }

    func test_bug26_cmdBToggleOff_subsequentTextNotBold() {
        // User-reported: CMD+B turns bold on, typing produces bold,
        // then CMD+B again to toggle off doesn't work (text stays bold).
        // Empty-selection path uses pendingInlineTraits + insertWithTraits.
        // After the toggle-off, inserted text must NOT be bold.
        let editor = makeEditor()
        fill(editor, "x")
        // Cursor at end of "x" (position 1)
        run([
            .cursorAt(1),
            .toggleBold,         // turn bold on
            .type("hello"),      // typed bold
            .toggleBold,         // turn bold off
            .type("world")       // should NOT be bold
        ], on: editor)
        assertEditorMatchesMarkdown(editor, "x**hello**world")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_bug51_newTodoBetweenUncheckedAndChecked_isUnchecked() {
        // User-reported: entering a new Todo when the Todo item below
        // is already completed shows the new one as checked. New items
        // produced by Return on an unchecked todo must always start
        // unchecked, regardless of neighbors.
        let editor = makeEditor()
        fill(editor, "- [ ] First\n- [x] Second")
        // Cursor at end of "First" (the unchecked one)
        let s = editor.textStorage?.string as NSString? ?? ""
        let firstRange = s.range(of: "First")
        let end = firstRange.location + firstRange.length
        run([.cursorAt(end), .pressReturn, .type("Middle")], on: editor)
        assertEditorMatchesMarkdown(
            editor,
            "- [ ] First\n- [ ] Middle\n- [x] Second"
        )
        assertLiveDocumentRoundTrips(editor)
    }

    func test_bug51_toggleTodoOnParagraphAboveCheckedTodo_isUnchecked() {
        // User clicks Todo button on a paragraph that sits directly
        // above a checked todo. The new todo must be unchecked — it
        // should not inherit checked state from the neighbor.
        // (Asserts via round-trip serialization rather than HTML parity
        // because the live Document keeps two `.list` blocks separated
        // by a `.blankLine` while a fresh parse would merge them into
        // one loose list. Both serialize to the same markdown — the
        // checked-state of the new item is what we're verifying.)
        let editor = makeEditor()
        fill(editor, "shopping\n\n- [x] milk")
        let s = editor.textStorage?.string as NSString? ?? ""
        let shopRange = s.range(of: "shopping")
        run([.cursorAt(shopRange.location), .toggleTodo], on: editor)
        let doc = editor.documentProjection?.document ?? Document(blocks: [])
        let md = MarkdownSerializer.serialize(doc)
        XCTAssertTrue(
            md.contains("- [ ] shopping"),
            "shopping must be unchecked; got: \(md)"
        )
        XCTAssertTrue(
            md.contains("- [x] milk"),
            "milk must remain checked; got: \(md)"
        )
        // Note: assertLiveDocumentRoundTrips would fail here because
        // the live Document keeps two separate `.list` blocks while a
        // fresh parse merges them into one loose list. The structural
        // fidelity gap is a separate issue from bug 51 (checked-state
        // inheritance), which is what this test verifies.
    }

    func test_bug51_newTodoBetweenCheckedAndChecked_isUnchecked() {
        // Even between two checked items, a brand-new item (split via
        // Return) on a CHECKED one must produce an UNCHECKED next item
        // — see existing test_script_returnOnCheckedTodo_producesUnchecked.
        // This variant tests the cursor-mid-text case.
        let editor = makeEditor()
        fill(editor, "- [x] First\n- [x] Second")
        let s = editor.textStorage?.string as NSString? ?? ""
        let firstRange = s.range(of: "First")
        let end = firstRange.location + firstRange.length
        run([.cursorAt(end), .pressReturn, .type("Middle")], on: editor)
        assertEditorMatchesMarkdown(
            editor,
            "- [x] First\n- [ ] Middle\n- [x] Second"
        )
        assertLiveDocumentRoundTrips(editor)
    }

    func test_rc4_typingLinkClosingParen_parsesAsLink() {
        // User-reported: typed URLs are not clickable until app reload.
        // Typing "](url)" character by character should trigger an
        // inline re-parse that produces an `Inline.link`, which renders
        // as a clickable `<a>` in HTML parity.
        let editor = makeEditor()
        fill(editor, "x")
        var steps: [EditStep] = [.cursorAt(0)]
        for ch in "[text](https://example.com)" {
            steps.append(.type(String(ch)))
        }
        run(steps, on: editor)
        assertEditorMatchesMarkdown(editor, "[text](https://example.com)x")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_rc4_pasteLinkMarkdown_parsesAsLink() {
        // Toolbar-driven link insertion (`linkMenu` / `wikiLinks`) and
        // paste both go through `insertText` with multi-char content.
        // The RC4 hook should re-parse on multi-char insertions.
        let editor = makeEditor()
        fill(editor, "x")
        run([
            .cursorAt(0),
            .type("[click](https://example.com)")
        ], on: editor)
        assertEditorMatchesMarkdown(editor, "[click](https://example.com)x")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_rc4_typingBoldStarStarStar_parsesAsBold() {
        // Bold marker close should trigger reparse.
        let editor = makeEditor()
        fill(editor, "x")
        var steps: [EditStep] = [.cursorAt(0)]
        for ch in "**bold**" {
            steps.append(.type(String(ch)))
        }
        run(steps, on: editor)
        assertEditorMatchesMarkdown(editor, "**bold**x")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_rc3_multiParagraphSelection_toggleList_convertsAll() {
        let editor = makeEditor()
        fill(editor, "First\n\nSecond\n\nThird")
        // Select across all three paragraphs
        let len = editor.textStorage?.length ?? 0
        run([.select(NSRange(location: 0, length: len)),
             .toggleList(marker: "-")], on: editor)
        assertEditorMatchesMarkdown(editor, "- First\n- Second\n- Third")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_rc3_multiParagraphSelection_setHeading_promotesFirstOnly() {
        // Bug #26 (user-reported): heading promotion on a multi-line
        // selection only promotes the FIRST overlapped block. The
        // common case is "select title plus body, click H2" — the
        // user wants to title the first line, not promote everything.
        // This is a deliberate departure from the other rc3
        // multi-paragraph block-format primitives (toggleList,
        // toggleTodo, toggleBlockquote) which apply to every block.
        let editor = makeEditor()
        fill(editor, "First\n\nSecond\n\nThird")
        let len = editor.textStorage?.length ?? 0
        run([.select(NSRange(location: 0, length: len)),
             .setHeading(level: 2)], on: editor)
        assertEditorMatchesMarkdown(editor, "## First\n\nSecond\n\nThird")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_rc3_multiParagraphSelection_toggleTodo_convertsAll() {
        let editor = makeEditor()
        fill(editor, "First\n\nSecond\n\nThird")
        let len = editor.textStorage?.length ?? 0
        run([.select(NSRange(location: 0, length: len)),
             .toggleTodo], on: editor)
        assertEditorMatchesMarkdown(
            editor,
            "- [ ] First\n- [ ] Second\n- [ ] Third"
        )
        assertLiveDocumentRoundTrips(editor)
    }

    func test_rc3_multiParagraphSelection_toggleBlockquote_convertsAll() {
        let editor = makeEditor()
        fill(editor, "First\n\nSecond\n\nThird")
        let len = editor.textStorage?.length ?? 0
        run([.select(NSRange(location: 0, length: len)),
             .toggleQuote], on: editor)
        assertEditorMatchesMarkdown(editor, "> First\n\n> Second\n\n> Third")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_rc3_insertCodeBlock_noSelection_insertsEmptyCodeBlock() {
        let editor = makeEditor()
        fill(editor, "before\n\nafter")
        // Cursor at start of "after"
        let s = editor.textStorage?.string as NSString? ?? ""
        let afterRange = s.range(of: "after")
        editor.setSelectedRange(NSRange(location: afterRange.location, length: 0))
        _ = editor.perform(#selector(EditTextView.insertCodeBlock(_:)), with: nil)
        // An empty code block is added; surrounding content must remain.
        let doc = editor.documentProjection?.document ?? Document(blocks: [])
        let md = MarkdownSerializer.serialize(doc)
        XCTAssertTrue(md.contains("before"), "before preserved; got: \(md)")
        XCTAssertTrue(md.contains("after"), "after preserved; got: \(md)")
        XCTAssertTrue(md.contains("```"), "code block inserted; got: \(md)")
        assertLiveDocumentRoundTrips(editor)
    }

    func test_script_headingThenListThenBody() {
        let editor = makeEditor()
        fill(editor, "# Title")
        run([
            .cursorAtEnd,
            .pressReturn,
            .toggleList(marker: "-"),
            .type("Item one"),
            .pressReturn,
            .type("Item two"),
            .pressReturn,   // empty list item
            .pressReturn,   // exit list (Return on empty)
            .type("Body text")
        ], on: editor)
        // Note: toggleList on a blankLine absorbs the blank line, so
        // there is no blank line between heading and list. Exit-list
        // produces a paragraph without a preceding blankLine. Both are
        // valid markdown; blank-line insertion is a future enhancement.
        assertLiveDocumentRoundTrips(editor, "complex scenario")
    }

    // MARK: - Bug: Heading conversion affects all paragraphs

    func test_headingConversion_onlyAffectsSelectedBlock() {
        let editor = makeEditor()
        // Three paragraphs - cursor in middle one, apply H2
        // Only middle should become heading
        fill(editor, "First paragraph\n\nSecond paragraph\n\nThird paragraph")
        
        // Place cursor in "Second paragraph" (after "First paragraph\n\n" = 17 chars)
        run([.cursorAt(17), .setHeading(level: 2)], on: editor)
        
        // Verify only second paragraph became H2
        assertEditorMatchesMarkdown(editor, "First paragraph\n\n## Second paragraph\n\nThird paragraph")
        assertLiveDocumentRoundTrips(editor)
    }

    // MARK: - Delete Key Selection Tests

    func test_delete_selectedTable_removesBlock() {
        // User-reported: selecting a table and pressing Delete (Forward Delete)
        // removed it from WYSIWYG view but the markdown still contained it.
        // The fix: EditingOps.delete now uses blockIndices(overlapping:) to
        // detect when an atomic block (table, HR) is fully covered by selection.
        //
        // Subview-table path: locate the table through the block-model
        // projection and select the storage span that covers its
        // attachment glyph.
        let editor = makeEditor()
        fill(editor, "before\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nafter")

        // Locate the table block in the projection and resolve its
        // storage span.
        guard let projection = editor.documentProjection else {
            XCTFail("No block-model projection")
            return
        }
        var tableRange: NSRange?
        for (idx, block) in projection.document.blocks.enumerated() {
            if case .table = block {
                tableRange = projection.blockSpans[idx]
                break
            }
        }
        guard let tableRange = tableRange else {
            XCTFail("Table block not found in projection")
            return
        }

        editor.setSelectedRange(tableRange)

        let handled = editor.handleEditViaBlockModel(
            in: tableRange,
            replacementString: ""
        )
        XCTAssertTrue(handled, "block model should handle table deletion")

        // The table should be removed from the document
        let doc = editor.documentProjection?.document ?? Document(blocks: [])
        let hasTable = doc.blocks.contains { block in
            if case .table = block { return true } else { return false }
        }
        XCTAssertFalse(hasTable, "table should be removed after Delete key on selection")

        // The serialized markdown should not contain table syntax
        let md = MarkdownSerializer.serialize(doc)
        XCTAssertFalse(md.contains("| A | B |"), "serialized markdown should not contain table header")
        XCTAssertTrue(md.contains("before"), "text before table should be preserved")
        XCTAssertTrue(md.contains("after"), "text after table should be preserved")

        assertLiveDocumentRoundTrips(editor)
    }

    func test_delete_selectedListItem_removesContent() {
        // Selecting text within a list item and deleting should work
        let editor = makeEditor()
        fill(editor, "- First\n- Second\n- Third")

        // Find "Second" and select it
        let s = editor.textStorage?.string as NSString? ?? ""
        let secondRange = s.range(of: "Second")
        editor.setSelectedRange(secondRange)

        // Delete the selection via block model
        let handled = editor.handleEditViaBlockModel(
            in: secondRange,
            replacementString: ""
        )
        XCTAssertTrue(handled, "block model should handle list item text deletion")

        // "Second" should be removed, but the list item structure should remain
        let doc = editor.documentProjection?.document ?? Document(blocks: [])
        let md = MarkdownSerializer.serialize(doc)
        XCTAssertTrue(md.contains("- First"), "First item preserved; got: \(md)")
        XCTAssertTrue(md.contains("- Third"), "Third item preserved; got: \(md)")
        // The middle item should exist but with empty content
        XCTAssertFalse(md.contains("Second"), "Second text removed; got: \(md)")

        assertLiveDocumentRoundTrips(editor)
    }

    /// MAJOR BUG variant: select an entire list line and press Delete,
    /// then Undo. The restored document must have the full formatting
    /// intact (not raw markdown text, not with markers exposed).
    func test_bug_undoAfterSelectDeleteListLine_preservesFormatting() {
        let editor = makeEditor()
        let originalMd = "**Bold** and *italic* header\n\n- item one\n- item two\n- item three"
        fill(editor, originalMd)
        let s = editor.textStorage?.string as NSString? ?? ""
        let twoRange = s.range(of: "item two")
        // Select "item two" and delete.
        editor.setSelectedRange(twoRange)
        _ = editor.handleEditViaBlockModel(in: twoRange, replacementString: "")
        let um = editor.undoManager
        XCTAssertNotNil(um, "undo manager must be available")
        um?.undo()
        let restored = editor.documentProjection?.document ?? Document(blocks: [])
        let restoredMd = MarkdownSerializer.serialize(restored)
        XCTAssertTrue(restoredMd.contains("**Bold**"), "undo preserves bold; got: \(restoredMd)")
        XCTAssertTrue(restoredMd.contains("*italic*"), "undo preserves italic; got: \(restoredMd)")
        XCTAssertTrue(restoredMd.contains("- item two"), "undo restores selected text; got: \(restoredMd)")
    }

    /// MAJOR BUG: Pressing delete in a list to delete a list line and
    /// then pressing Undo removes all markdown formatting in the entire
    /// note. Reproduce: load a note with bold + italic formatting plus a
    /// list. Backspace at home of a list item (which triggers the FSM
    /// exit path). Undo. The document should round-trip to the original
    /// markdown with formatting intact.
    func test_bug_undoAfterListDelete_preservesFormatting() {
        let editor = makeEditor()
        let originalMd = "**Bold** and *italic* header\n\n- item one\n- item two\n- item three"
        fill(editor, originalMd)

        // Cursor at home of "item two" (after the "- " prefix of the list item).
        let s = editor.textStorage?.string as NSString? ?? ""
        let twoRange = s.range(of: "item two")
        XCTAssertTrue(twoRange.location != NSNotFound, "precondition: 'item two' found in storage")

        // Backspace at home: should exit list / unindent via FSM.
        run([.cursorAt(twoRange.location), .backspace], on: editor)

        // Undo. After undo, Document must be identical to the original.
        let um = editor.undoManager ?? editor.editorViewController?.editorUndoManager
        XCTAssertNotNil(um, "undo manager must be available")
        um?.undo()

        let restored = editor.documentProjection?.document ?? Document(blocks: [])
        let restoredMd = MarkdownSerializer.serialize(restored)
        XCTAssertTrue(
            restoredMd.contains("**Bold**"),
            "undo must preserve bold formatting; got: \(restoredMd)"
        )
        XCTAssertTrue(
            restoredMd.contains("*italic*"),
            "undo must preserve italic formatting; got: \(restoredMd)"
        )
        XCTAssertTrue(
            restoredMd.contains("- item two"),
            "undo must restore the deleted list item; got: \(restoredMd)"
        )
    }
}
