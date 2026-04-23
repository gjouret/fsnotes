//
//  CodeBlockEditToggleTests.swift
//  FSNotesTests
//
//  Code-Block Edit Toggle — Slice 1 coverage.
//
//  Scope: the renderer flag is threaded through
//  `DocumentRenderer.render(...)` / `CodeBlockRenderer.render(...)` /
//  `DocumentEditApplier.applyDocumentEdit(...)`. No UI, no hover
//  button, no cursor-leaves observer. The flag is set directly by
//  the tests to prove the renderer output differs.
//
//  Six tests:
//    1. test_slice1_regularCodeBlock_editingFormEmitsFences
//    2. test_slice1_regularCodeBlock_defaultFormStripsFences
//    3. test_slice1_mermaidBlock_editingFormEmitsFences_notAttachment
//    4. test_slice1_mermaidBlock_defaultFormEmitsAttachment
//    5. test_slice1_applyDocumentEdit_toggleFlagProducesBlockLevelDiff
//    6. test_slice1_blockRef_stableAcrossUnrelatedBlockInsert
//

import XCTest
import AppKit
@testable import FSNotes

final class CodeBlockEditToggleTests: XCTestCase {

    // MARK: - Helpers

    private func bodyFont() -> PlatformFont {
        return PlatformFont.systemFont(ofSize: 14)
    }
    private func codeFont() -> PlatformFont {
        return PlatformFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    }

    /// Object-Replacement-Character (`U+FFFC`) — the single Unicode
    /// scalar that stands in for any `NSTextAttachment` in the
    /// storage string.
    private static let objectReplacement = "\u{FFFC}"

    /// Build an `NSTextContentStorage` pre-seeded with the rendered
    /// output of `document` under the given `editingCodeBlocks`.
    /// Mirrors the wiring `EditTextView` installs on TK2.
    private func makeSeededContentStorage(
        for document: Document,
        editingCodeBlocks: Set<BlockRef> = []
    ) -> (NSTextContentStorage, NSTextLayoutManager, RenderedDocument) {
        let rendered = DocumentRenderer.render(
            document,
            bodyFont: bodyFont(),
            codeFont: codeFont(),
            editingCodeBlocks: editingCodeBlocks
        )
        let contentStorage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        contentStorage.addTextLayoutManager(layoutManager)
        let delegate = BlockModelContentStorageDelegate()
        contentStorage.delegate = delegate
        objc_setAssociatedObject(
            contentStorage, Unmanaged.passUnretained(self).toOpaque(),
            delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        contentStorage.performEditingTransaction {
            contentStorage.textStorage?.setAttributedString(rendered.attributed)
        }
        return (contentStorage, layoutManager, rendered)
    }

    // MARK: - 1. Regular code block, editing form

    /// Editing form: the block emits the canonical fenced markdown
    /// form — open fence + language + `\n` + content + `\n` + close
    /// fence. Zero syntax highlighting, plain monospaced code font.
    func test_slice1_regularCodeBlock_editingFormEmitsFences() {
        let pythonBlock = Block.codeBlock(
            language: "python",
            content: "print('hi')",
            fence: FenceStyle.canonical(language: "python")
        )
        let doc = Document(blocks: [pythonBlock], trailingNewline: false)
        let ref = BlockRef(pythonBlock)

        let rendered = DocumentRenderer.render(
            doc,
            bodyFont: bodyFont(),
            codeFont: codeFont(),
            editingCodeBlocks: [ref]
        )
        let str = rendered.attributed.string

        XCTAssertTrue(
            str.contains("\u{0060}\u{0060}\u{0060}python\n"),
            "editing form must open with ```python\\n — got \(str.debugDescription)"
        )
        XCTAssertTrue(
            str.hasSuffix("\u{0060}\u{0060}\u{0060}"),
            "editing form must close with ``` — got \(str.debugDescription)"
        )
        XCTAssertTrue(
            str.contains("print('hi')"),
            "editing form must include raw code content verbatim — got \(str.debugDescription)"
        )
        XCTAssertFalse(
            str.contains(Self.objectReplacement),
            "editing form must NOT include any attachment character — got \(str.debugDescription)"
        )
    }

    // MARK: - 2. Regular code block, default form

    /// Default form: zero backtick characters in the rendered storage.
    /// Same byte-for-byte behaviour as before slice 1.
    func test_slice1_regularCodeBlock_defaultFormStripsFences() {
        let pythonBlock = Block.codeBlock(
            language: "python",
            content: "print('hi')",
            fence: FenceStyle.canonical(language: "python")
        )
        let doc = Document(blocks: [pythonBlock], trailingNewline: false)

        let rendered = DocumentRenderer.render(
            doc,
            bodyFont: bodyFont(),
            codeFont: codeFont()
        )
        let str = rendered.attributed.string

        XCTAssertFalse(
            str.contains("\u{0060}"),
            "default form must contain zero backticks — got \(str.debugDescription)"
        )
        XCTAssertTrue(
            str.contains("print('hi')"),
            "default form must still carry the raw code content — got \(str.debugDescription)"
        )
    }

    // MARK: - 3. Mermaid block, editing form (fences, no attachment)

    /// Editing form on a mermaid block: emits the source verbatim
    /// wrapped in mermaid fences. No attachment (U+FFFC) character.
    /// The `DocumentRenderer.blockModelKind` downgrade routes it
    /// through `CodeBlockLayoutFragment` (not `MermaidLayoutFragment`)
    /// so the rendered output is just plain fenced text.
    func test_slice1_mermaidBlock_editingFormEmitsFences_notAttachment() {
        let mermaidSource = "graph LR\n  A-->B"
        let mermaidBlock = Block.codeBlock(
            language: "mermaid",
            content: mermaidSource,
            fence: FenceStyle.canonical(language: "mermaid")
        )
        let doc = Document(blocks: [mermaidBlock], trailingNewline: false)
        let ref = BlockRef(mermaidBlock)

        let rendered = DocumentRenderer.render(
            doc,
            bodyFont: bodyFont(),
            codeFont: codeFont(),
            editingCodeBlocks: [ref]
        )
        let str = rendered.attributed.string
        let blockRange = rendered.blockSpans[0]
        let blockStr = (str as NSString).substring(with: blockRange)

        XCTAssertTrue(
            blockStr.contains("\u{0060}\u{0060}\u{0060}mermaid\n"),
            "mermaid editing form must open with ```mermaid\\n — got \(blockStr.debugDescription)"
        )
        XCTAssertTrue(
            blockStr.contains(mermaidSource),
            "mermaid editing form must include the raw source verbatim — got \(blockStr.debugDescription)"
        )
        XCTAssertTrue(
            blockStr.hasSuffix("\u{0060}\u{0060}\u{0060}"),
            "mermaid editing form must close with ``` — got \(blockStr.debugDescription)"
        )
        XCTAssertFalse(
            blockStr.contains(Self.objectReplacement),
            "mermaid editing form must NOT include any attachment (U+FFFC) character — got \(blockStr.debugDescription)"
        )
    }

    // MARK: - 4. Mermaid block, default form (attachment)

    /// Default form on a mermaid block preserves today's behaviour:
    /// exactly one U+FFFC attachment character in the block's range.
    func test_slice1_mermaidBlock_defaultFormEmitsAttachment() {
        let mermaidBlock = Block.codeBlock(
            language: "mermaid",
            content: "graph LR\n  A-->B",
            fence: FenceStyle.canonical(language: "mermaid")
        )
        let doc = Document(blocks: [mermaidBlock], trailingNewline: false)

        let rendered = DocumentRenderer.render(
            doc,
            bodyFont: bodyFont(),
            codeFont: codeFont()
        )
        let str = rendered.attributed.string
        let blockRange = rendered.blockSpans[0]
        let blockStr = (str as NSString).substring(with: blockRange)
        let attachmentCount = blockStr.components(separatedBy: Self.objectReplacement).count - 1

        XCTAssertEqual(
            attachmentCount, 1,
            "mermaid default form must have exactly one U+FFFC attachment — got \(attachmentCount) in \(blockStr.debugDescription)"
        )
    }

    // MARK: - 5. Toggle-only edit produces block-level diff

    /// With `priorDoc == newDoc` but editing-set membership flipped
    /// on a single block, the applier must report exactly one
    /// `elementsChanged` entry at that block's index. This is the
    /// proof that toggling the flag alone produces a minimal
    /// element-bounded re-render — no structural changes.
    func test_slice1_applyDocumentEdit_toggleFlagProducesBlockLevelDiff() {
        let para = Block.paragraph(inline: [.text("before")])
        let pythonBlock = Block.codeBlock(
            language: "python",
            content: "print('hi')",
            fence: FenceStyle.canonical(language: "python")
        )
        let trailer = Block.paragraph(inline: [.text("after")])
        let doc = Document(
            blocks: [para, pythonBlock, trailer],
            trailingNewline: false
        )
        let ref = BlockRef(pythonBlock)

        let (cs, _, priorRendered) = makeSeededContentStorage(
            for: doc, editingCodeBlocks: []
        )
        // Sanity: storage matches the prior render exactly.
        XCTAssertEqual(
            cs.textStorage?.string, priorRendered.attributed.string,
            "storage must match rendered prior doc before the toggle"
        )

        let report = DocumentEditApplier.applyDocumentEdit(
            priorDoc: doc, newDoc: doc,
            contentStorage: cs,
            bodyFont: bodyFont(), codeFont: codeFont(),
            priorEditingBlocks: [],
            newEditingBlocks: [ref]
        )

        XCTAssertEqual(
            report.elementsChanged, [1],
            "toggling the code block's editing flag must produce a single .modified at block index 1 — got \(report)"
        )
        XCTAssertTrue(
            report.elementsInserted.isEmpty,
            "toggle-only edit must NOT insert any block — got \(report.elementsInserted)"
        )
        XCTAssertTrue(
            report.elementsDeleted.isEmpty,
            "toggle-only edit must NOT delete any block — got \(report.elementsDeleted)"
        )
        XCTAssertFalse(
            report.wasNoop,
            "toggle-only edit must NOT be reported as a noop"
        )

        // Post-edit storage must match the NEW-form rendering.
        let newRendered = DocumentRenderer.render(
            doc,
            bodyFont: bodyFont(),
            codeFont: codeFont(),
            editingCodeBlocks: [ref]
        )
        XCTAssertEqual(
            cs.textStorage?.string, newRendered.attributed.string,
            "post-toggle storage.string must equal DocumentRenderer.render(editingCodeBlocks: [ref]).string"
        )
    }

    // MARK: - 6. BlockRef stability across unrelated insert-above

    /// Content-hash keying: inserting an unrelated paragraph BEFORE a
    /// shared code block must leave the code block's `BlockRef`
    /// unchanged. An index-keyed reference would flip from idx 0 to
    /// idx 1 and invalidate; a content-hash ref does not.
    func test_slice1_blockRef_stableAcrossUnrelatedBlockInsert() {
        let sharedCode = Block.codeBlock(
            language: "python",
            content: "print('hi')",
            fence: FenceStyle.canonical(language: "python")
        )

        let docA = Document(
            blocks: [
                sharedCode,
                .paragraph(inline: [.text("trailer")])
            ],
            trailingNewline: false
        )
        let docB = Document(
            blocks: [
                .paragraph(inline: [.text("inserted above")]),
                sharedCode,
                .paragraph(inline: [.text("trailer")])
            ],
            trailingNewline: false
        )

        let refA = BlockRef(docA.blocks[0])   // code block at idx 0 in A
        let refB = BlockRef(docB.blocks[1])   // SAME code block at idx 1 in B

        XCTAssertEqual(
            refA, refB,
            "BlockRef must be stable across insert-above structural edits — refA=\(refA) refB=\(refB)"
        )
    }
}
