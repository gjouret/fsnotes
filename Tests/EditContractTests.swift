//
//  EditContractTests.swift
//  FSNotesTests
//
//  Phase 1 pilot: prove the EditContract / assertContract mechanism
//  actually catches bugs. Two positive tests validate that a
//  correctly-populated contract passes; one negative test validates
//  that the harness catches a lying contract — if it didn't, the
//  whole apparatus would be decorative.
//

import XCTest
@testable import FSNotes

final class EditContractTests: XCTestCase {

    private func bodyFont() -> PlatformFont { .systemFont(ofSize: 14) }
    private func codeFont() -> PlatformFont {
        .monospacedSystemFont(ofSize: 14, weight: .regular)
    }
    private func project(_ md: String) -> DocumentProjection {
        let doc = MarkdownParser.parse(md)
        return DocumentProjection(
            document: doc,
            bodyFont: bodyFont(),
            codeFont: codeFont()
        )
    }

    // MARK: - Positive: changeHeadingLevel populates a valid contract

    func test_changeHeadingLevel_paragraphToHeading_contractMatches() throws {
        let before = project("First\n\nSecond\n\nThird")
        let offset = 7  // inside "Second"
        let result = try EditingOps.changeHeadingLevel(2, at: offset, in: before)

        guard let contract = result.contract else {
            return XCTFail("Pilot primitive must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.changeBlockKind(at: 2)],
            "Paragraph→heading should declare changeBlockKind on the target block"
        )
        // Harness verifies the declared diff matches the actual diff.
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    func test_changeHeadingLevel_toggleOffToParagraph_contractMatches() throws {
        let before = project("# Heading\n\nBody")
        let offset = 2  // inside heading text
        let result = try EditingOps.changeHeadingLevel(1, at: offset, in: before)

        guard let contract = result.contract else {
            return XCTFail("Pilot primitive must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.changeBlockKind(at: 0)]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    func test_changeHeadingLevel_paragraphNoOp_emptyContractMatches() throws {
        let before = project("Just a paragraph")
        let result = try EditingOps.changeHeadingLevel(0, at: 3, in: before)

        guard let contract = result.contract else {
            return XCTFail("No-op branch must still populate contract")
        }
        XCTAssertTrue(
            contract.declaredActions.isEmpty,
            "No-op must declare no actions"
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    // MARK: - toggleBlockquote

    func test_toggleBlockquote_paragraphToQuote_contractMatches() throws {
        let before = project("Before\n\nBody text\n\nAfter")
        // Find offset inside "Body text" (block 2).
        let bodyOffset = before.blockSpans[2].location + 1
        let result = try EditingOps.toggleBlockquote(at: bodyOffset, in: before)

        guard let contract = result.contract else {
            return XCTFail("toggleBlockquote must populate contract")
        }
        XCTAssertEqual(contract.declaredActions, [.changeBlockKind(at: 2)])
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    func test_toggleBlockquote_quoteToParagraph_contractMatches() throws {
        let before = project("> Quote line\n\nParagraph")
        let result = try EditingOps.toggleBlockquote(at: 2, in: before)

        guard let contract = result.contract else {
            return XCTFail("toggleBlockquote must populate contract")
        }
        XCTAssertEqual(contract.declaredActions, [.changeBlockKind(at: 0)])
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    // MARK: - toggleTodoCheckbox

    func test_toggleTodoCheckbox_uncheckedToChecked_contractMatches() throws {
        let before = project("- [ ] Task one\n- [ ] Task two")
        // Offset inside first item's text.
        let offset = before.blockSpans[0].location + 5
        let result = try EditingOps.toggleTodoCheckbox(at: offset, in: before)

        guard let contract = result.contract else {
            return XCTFail("toggleTodoCheckbox must populate contract")
        }
        XCTAssertEqual(contract.declaredActions, [.modifyInline(blockIndex: 0)])
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    func test_toggleTodoCheckbox_plainListToTodo_contractMatches() throws {
        let before = project("- Regular item\n- Another")
        let offset = before.blockSpans[0].location + 3
        let result = try EditingOps.toggleTodoCheckbox(at: offset, in: before)

        guard let contract = result.contract else {
            return XCTFail("toggleTodoCheckbox must populate contract")
        }
        XCTAssertEqual(contract.declaredActions, [.modifyInline(blockIndex: 0)])
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    // MARK: - insertHorizontalRule

    func test_insertHorizontalRule_afterParagraph_contractMatches() throws {
        let before = project("Para one\n\nPara two")
        let offset = 2  // inside "Para one"
        let result = try EditingOps.insertHorizontalRule(at: offset, in: before)

        guard let contract = result.contract else {
            return XCTFail("insertHorizontalRule must populate contract")
        }
        // Inserted: blankLine, HR. Next block is a paragraph → no
        // trailing paragraph needed.
        XCTAssertEqual(
            contract.declaredActions,
            [.insertBlock(at: 1), .insertBlock(at: 2)],
            "HR after a paragraph with another paragraph next should insert blankLine + HR only"
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    func test_insertHorizontalRule_atEOF_contractMatches() throws {
        let before = project("Only paragraph")
        let offset = 3
        let result = try EditingOps.insertHorizontalRule(at: offset, in: before)

        guard let contract = result.contract else {
            return XCTFail("insertHorizontalRule must populate contract")
        }
        // EOF case: blankLine + HR + trailing paragraph.
        XCTAssertEqual(
            contract.declaredActions,
            [.insertBlock(at: 1), .insertBlock(at: 2), .insertBlock(at: 3)],
            "HR at EOF should insert blankLine + HR + trailing paragraph"
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    // MARK: - toggleInlineTrait

    func test_toggleInlineTrait_paragraph_contractMatches() throws {
        let before = project("Hello world\n\nNext")
        // Select "Hello" (offset 0..<5 in block 0)
        let result = try EditingOps.toggleInlineTrait(
            .bold,
            range: NSRange(location: 0, length: 5),
            in: before
        )
        guard let contract = result.contract else {
            return XCTFail("toggleInlineTrait must populate contract")
        }
        XCTAssertEqual(contract.declaredActions, [.modifyInline(blockIndex: 0)])
        XCTAssertEqual(contract.postSelectionLength, 5)
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    func test_toggleInlineTrait_zeroLengthSelection_emptyContract() throws {
        let before = project("Hello")
        let result = try EditingOps.toggleInlineTrait(
            .bold,
            range: NSRange(location: 2, length: 0),
            in: before
        )
        guard let contract = result.contract else {
            return XCTFail("Zero-length branch must populate contract")
        }
        XCTAssertTrue(contract.declaredActions.isEmpty)
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    // MARK: - insertWithTraits

    func test_insertWithTraits_intoParagraph_contractMatches() throws {
        let before = project("Hello")
        let result = try EditingOps.insertWithTraits(
            "X",
            traits: [.bold],
            at: 3,
            in: before
        )
        guard let contract = result.contract else {
            return XCTFail("insertWithTraits must populate contract")
        }
        XCTAssertEqual(contract.declaredActions, [.modifyInline(blockIndex: 0)])
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    // MARK: - reparseInlinesIfNeeded

    /// Typing `[text](url)` character by character builds up `.text`
    /// nodes; the reparse pass detects the completed pattern and
    /// replaces the paragraph's inline tree with a real `.link`.
    /// Contract must declare modifyInline on the affected block.
    func test_reparseInlinesIfNeeded_linkDetection_contractMatches() throws {
        // Build a paragraph whose serialized form re-parses to a link,
        // but whose current inline tree is plain text. Constructing a
        // fresh projection from markdown yields the parsed form, so we
        // synthesize the "not-yet-reparsed" state by hand.
        let plainInlines: [Inline] = [.text("[link](https://example.com)")]
        let plainDoc = Document(blocks: [.paragraph(inline: plainInlines)], trailingNewline: false)
        let before = DocumentProjection(
            document: plainDoc,
            bodyFont: bodyFont(),
            codeFont: codeFont()
        )

        guard let result = try EditingOps.reparseInlinesIfNeeded(blockIndex: 0, in: before) else {
            return XCTFail("Completed link pattern should trigger reparse")
        }
        guard let contract = result.contract else {
            return XCTFail("reparseInlinesIfNeeded must populate contract")
        }
        XCTAssertEqual(contract.declaredActions, [.modifyInline(blockIndex: 0)])
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    // MARK: - insertImage

    func test_insertImage_intoParagraph_contractMatches() throws {
        let before = project("Hello world\n\nTrailing")
        let offset = 3  // inside "Hello world" (block 0)
        let result = try EditingOps.insertImage(
            alt: "alt",
            destination: "image.png",
            at: offset,
            in: before
        )
        guard let contract = result.contract else {
            return XCTFail("insertImage must populate contract")
        }
        XCTAssertEqual(contract.declaredActions, [.insertBlock(at: 1)])
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    // MARK: - wrapInCodeBlock

    func test_wrapInCodeBlock_cursorOnly_contractMatches() throws {
        let before = project("Paragraph\n\nNext")
        let result = try EditingOps.wrapInCodeBlock(
            range: NSRange(location: 3, length: 0),
            in: before
        )
        guard let contract = result.contract else {
            return XCTFail("wrapInCodeBlock must populate contract")
        }
        // Original block preserved, two new blocks inserted after it.
        XCTAssertEqual(
            contract.declaredActions,
            [.insertBlock(at: 1), .insertBlock(at: 2)]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    func test_wrapInCodeBlock_wholeParagraph_contractMatches() throws {
        let before = project("Hello")
        let result = try EditingOps.wrapInCodeBlock(
            range: NSRange(location: 0, length: 5),
            in: before
        )
        guard let contract = result.contract else {
            return XCTFail("wrapInCodeBlock must populate contract")
        }
        // Full-paragraph selection → 1 original replaced with 1 code block.
        XCTAssertEqual(contract.declaredActions, [.replaceBlock(at: 0)])
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    func test_wrapInCodeBlock_partialHead_contractMatches() throws {
        let before = project("Hello world")
        // Select "world" (offset 6..<11); head "Hello " stays as leading paragraph.
        let result = try EditingOps.wrapInCodeBlock(
            range: NSRange(location: 6, length: 5),
            in: before
        )
        guard let contract = result.contract else {
            return XCTFail("wrapInCodeBlock must populate contract")
        }
        // 1 original replaced with 2 new (leadingPara + codeBlock).
        XCTAssertEqual(
            contract.declaredActions,
            [.replaceBlock(at: 0), .insertBlock(at: 1)]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    // MARK: - toggleList

    func test_toggleList_paragraphToList_noNeighborCoalesce_contractMatches() throws {
        let before = project("Alpha\n\nBeta\n\nGamma")
        // Offset inside "Beta" (block 2); neither neighbor is a list.
        let offset = before.blockSpans[2].location + 1
        let result = try EditingOps.toggleList(at: offset, in: before)
        guard let contract = result.contract else {
            return XCTFail("toggleList must populate contract")
        }
        XCTAssertEqual(contract.declaredActions, [.changeBlockKind(at: 2)])
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    func test_toggleList_paragraphToList_withSurroundingLists_contractMatches() throws {
        // Two lists separated by a blankLine and a paragraph. Promoting the
        // paragraph into a list leaves the blankLine between them — so the
        // coalesce DOES NOT merge (blankLine blocks it). Contract should
        // still match the observed structure.
        let before = project("- One\n\nBeta\n\n- Three")
        // Find the paragraph block.
        var betaIdx = -1
        for (i, b) in before.document.blocks.enumerated() {
            if case .paragraph = b { betaIdx = i; break }
        }
        XCTAssertGreaterThanOrEqual(betaIdx, 0)
        let offset = before.blockSpans[betaIdx].location + 1
        let result = try EditingOps.toggleList(at: offset, in: before)
        guard let contract = result.contract else {
            return XCTFail("toggleList must populate contract")
        }
        // Primary action must be the kind change.
        XCTAssertTrue(contract.declaredActions.contains(.changeBlockKind(at: betaIdx)))
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    func test_toggleList_listDemote_contractMatches() throws {
        let before = project("- One\n- Two\n- Three")
        // Offset inside "Two" (second item).
        // flattenList returns entries in render order; pick the 2nd item's inline.
        let entries = before.blockSpans[0]  // single list block
        let offsetInBlock = entries.location + 5  // rough middle of item 2
        let result = try EditingOps.toggleList(at: offsetInBlock, in: before)
        guard let contract = result.contract else {
            return XCTFail("toggleList must populate contract")
        }
        // First action must be replaceBlock(0). Other actions depend on split shape.
        XCTAssertEqual(contract.declaredActions.first, .replaceBlock(at: 0))
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    // MARK: - toggleListRange

    func test_toggleListRange_twoItems_contractMatches() throws {
        let before = project("- One\n- Two\n- Three")
        // Select broadly across items 1 and 2. The block span has one bullet
        // attachment per item and the inline text follows each.
        let blockSpan = before.blockSpans[0]
        let selection = NSRange(
            location: blockSpan.location + 2,
            length: 8
        )
        guard let result = try EditingOps.toggleListRange(
            selection: selection, in: before
        ) else {
            return XCTFail("toggleListRange should apply for multi-item selection")
        }
        guard let contract = result.contract else {
            return XCTFail("toggleListRange must populate contract")
        }
        XCTAssertEqual(contract.declaredActions.first, .replaceBlock(at: 0))
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    // MARK: - toggleTodoList

    func test_toggleTodoList_paragraphToTodo_contractMatches() throws {
        let before = project("Hello world")
        let offset = 2
        let result = try EditingOps.toggleTodoList(at: offset, in: before)
        guard let contract = result.contract else {
            return XCTFail("toggleTodoList must populate contract")
        }
        XCTAssertEqual(contract.declaredActions, [.changeBlockKind(at: 0)])
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    func test_toggleTodoList_listAddCheckboxes_contractMatches() throws {
        let before = project("- One\n- Two")
        // Offset inside first item.
        let offset = before.blockSpans[0].location + 2
        let result = try EditingOps.toggleTodoList(at: offset, in: before)
        guard let contract = result.contract else {
            return XCTFail("toggleTodoList must populate contract")
        }
        XCTAssertEqual(contract.declaredActions, [.modifyInline(blockIndex: 0)])
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    func test_toggleTodoList_unwrapAllTodos_contractMatches() throws {
        let before = project("- [ ] One\n- [ ] Two")
        let offset = before.blockSpans[0].location + 2
        let result = try EditingOps.toggleTodoList(at: offset, in: before)
        guard let contract = result.contract else {
            return XCTFail("toggleTodoList must populate contract")
        }
        // 1 list → 2 paragraphs: replaceBlock(0) + insertBlock(at:1).
        XCTAssertEqual(contract.declaredActions.first, .replaceBlock(at: 0))
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    // MARK: - List FSM ops (indent/unindent/exit)

    func test_indentListItem_contractMatches() throws {
        let before = project("- One\n- Two")
        // Offset inside second item (indexing beyond first marker+content+newline).
        let blockSpan = before.blockSpans[0]
        // Find an offset inside "Two" by using flattenList. Simpler: use
        // halfway through the block span.
        let offset = blockSpan.location + 5
        let result = try EditingOps.indentListItem(at: offset, in: before)
        guard let contract = result.contract else {
            return XCTFail("indentListItem must populate contract")
        }
        XCTAssertEqual(contract.declaredActions.first, .reindentList(range: 0..<1))
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    func test_unindentListItem_contractMatches() throws {
        // Build a nested list: One, then a child "Two".
        let before = project("- One\n  - Two")
        let blockSpan = before.blockSpans[0]
        // Target the nested "Two". Heuristic offset that lands inside it.
        let offset = blockSpan.location + blockSpan.length - 2
        let result = try EditingOps.unindentListItem(at: offset, in: before)
        guard let contract = result.contract else {
            return XCTFail("unindentListItem must populate contract")
        }
        XCTAssertEqual(contract.declaredActions.first, .reindentList(range: 0..<1))
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    func test_exitListItem_contractMatches() throws {
        let before = project("- One\n- Two\n- Three")
        let blockSpan = before.blockSpans[0]
        // Target "Two" (middle item). Offset in the middle of the block.
        let offset = blockSpan.location + blockSpan.length / 2
        let result = try EditingOps.exitListItem(at: offset, in: before)
        guard let contract = result.contract else {
            return XCTFail("exitListItem must populate contract")
        }
        XCTAssertEqual(contract.declaredActions.first, .replaceBlock(at: 0))
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    // MARK: - Block/list-item move

    func test_moveBlockUp_contractMatches() throws {
        // "Alpha\n\nBeta" parses as 3 blocks: paragraph, blankLine, paragraph.
        // moveBlockUp(blockIndex: 2) swaps indices 1 and 2 — the block move
        // primitive is raw; it does not treat blankLines specially. Callers
        // (EditTextView+MoveLines) select block indices based on cursor
        // location, so the "Beta" paragraph sits at block 2.
        let before = project("Alpha\n\nBeta")
        XCTAssertEqual(before.document.blocks.count, 3)
        let result = try EditingOps.moveBlockUp(blockIndex: 2, in: before)
        guard let contract = result.contract else {
            return XCTFail("moveBlockUp must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.replaceBlock(at: 1), .replaceBlock(at: 2)]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        // Verify the swap actually happened: block 1 is now the paragraph,
        // block 2 is now the blankLine.
        if case .paragraph = result.newProjection.document.blocks[1] {} else {
            XCTFail("Block 1 should be the moved paragraph")
        }
        if case .blankLine = result.newProjection.document.blocks[2] {} else {
            XCTFail("Block 2 should be the blankLine")
        }
    }

    func test_moveBlockDown_contractMatches() throws {
        let before = project("Alpha\n\nBeta")
        XCTAssertEqual(before.document.blocks.count, 3)
        // Move "Alpha" (block 0) down: swap indices 0 and 1.
        let result = try EditingOps.moveBlockDown(blockIndex: 0, in: before)
        guard let contract = result.contract else {
            return XCTFail("moveBlockDown must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.replaceBlock(at: 0), .replaceBlock(at: 1)]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        if case .blankLine = result.newProjection.document.blocks[0] {} else {
            XCTFail("Block 0 should now be the blankLine")
        }
        if case .paragraph = result.newProjection.document.blocks[1] {} else {
            XCTFail("Block 1 should now be the paragraph Alpha")
        }
    }

    func test_moveListItemUp_contractMatches() throws {
        // Three-item list so the second item has a previous sibling.
        let before = project("- One\n- Two\n- Three")
        let blockSpan = before.blockSpans[0]
        // Target the middle item. Offset roughly in the middle of the block.
        let offset = blockSpan.location + blockSpan.length / 2
        let result = try EditingOps.moveListItemOrBlockUp(at: offset, in: before)
        guard let contract = result.contract else {
            return XCTFail("moveListItemOrBlockUp must populate contract")
        }
        // Only the single list block mutated (internal reorder).
        XCTAssertEqual(contract.declaredActions, [.replaceBlock(at: 0)])
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    func test_moveListItemDown_contractMatches() throws {
        let before = project("- One\n- Two\n- Three")
        let blockSpan = before.blockSpans[0]
        // Target the first item (has a next sibling).
        let offset = blockSpan.location + 3
        let result = try EditingOps.moveListItemOrBlockDown(at: offset, in: before)
        guard let contract = result.contract else {
            return XCTFail("moveListItemOrBlockDown must populate contract")
        }
        XCTAssertEqual(contract.declaredActions, [.replaceBlock(at: 0)])
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    func test_moveListItemOrBlockUp_fallsBackToBlockSwap_contractMatches() throws {
        // A list followed by a paragraph; target the FIRST item in the list
        // (no previous sibling inside the list), so the entry point falls
        // back to block-level move. Actually the fall-through case is
        // "first item in list + previous BLOCK exists". Build: paragraph,
        // then list whose first item we target.
        let before = project("Alpha\n\n- One\n- Two")
        // Target the first list item ("One") inside block 1.
        let listSpan = before.blockSpans[1]
        let offset = listSpan.location + 3
        let result = try EditingOps.moveListItemOrBlockUp(at: offset, in: before)
        guard let contract = result.contract else {
            return XCTFail("moveListItemOrBlockUp fallback must populate contract")
        }
        // Fallback path = block swap. Input has 3 blocks (paragraph,
        // blankLine, list); falling back moves the list (block 2) up past
        // the blankLine (block 1). Contract declares swap(1, 2).
        XCTAssertEqual(
            contract.declaredActions,
            [.replaceBlock(at: 1), .replaceBlock(at: 2)]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    // MARK: - Table cell edits

    func test_replaceTableCellInline_bodyCell_contractMatches() throws {
        // Two-row body table. Edit cell (row 1, col 0).
        let md = "| A | B |\n| - | - |\n| a1 | b1 |\n| a2 | b2 |"
        let before = project(md)
        // Table is the first (and only) real block.
        let newInline: [Inline] = [.text("NEW")]
        let result = try EditingOps.replaceTableCellInline(
            blockIndex: 0,
            at: .body(row: 1, col: 0),
            inline: newInline,
            in: before
        )
        guard let contract = result.contract else {
            return XCTFail("replaceTableCellInline must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.replaceTableCell(blockIndex: 0, rowIndex: 1, colIndex: 0)]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        // Verify the cell content actually mutated.
        guard case .table(_, _, let rows, _) =
                result.newProjection.document.blocks[0] else {
            return XCTFail("Block 0 must remain a table")
        }
        XCTAssertEqual(rows[1][0].rawText, "NEW")
    }

    func test_replaceTableCellInline_headerCell_contractMatches() throws {
        let md = "| A | B |\n| - | - |\n| a1 | b1 |"
        let before = project(md)
        let newInline: [Inline] = [.text("HDR")]
        let result = try EditingOps.replaceTableCellInline(
            blockIndex: 0,
            at: .header(col: 1),
            inline: newInline,
            in: before
        )
        guard let contract = result.contract else {
            return XCTFail("replaceTableCellInline (header) must populate contract")
        }
        // Header row is encoded as rowIndex = -1.
        XCTAssertEqual(
            contract.declaredActions,
            [.replaceTableCell(blockIndex: 0, rowIndex: -1, colIndex: 1)]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        guard case .table(let header, _, _, _) =
                result.newProjection.document.blocks[0] else {
            return XCTFail("Block 0 must remain a table")
        }
        XCTAssertEqual(header[1].rawText, "HDR")
    }

    func test_replaceTableCell_rawStringForwarder_contractMatches() throws {
        // The String-based entry point parses via MarkdownParser.parseInlines
        // and forwards to replaceTableCellInline — contract must survive.
        let md = "| A | B |\n| - | - |\n| a1 | b1 |"
        let before = project(md)
        let result = try EditingOps.replaceTableCell(
            blockIndex: 0,
            at: .body(row: 0, col: 1),
            newSourceText: "**bold**",
            in: before
        )
        guard let contract = result.contract else {
            return XCTFail("replaceTableCell (raw-string forwarder) must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.replaceTableCell(blockIndex: 0, rowIndex: 0, colIndex: 1)]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    // MARK: - Negative: harness catches a lying contract

    /// Smoke-test the invariant itself. If a primitive were to declare
    /// "no structural change" but actually mutate blocks, the harness
    /// MUST fail. We fabricate that case by running a real edit and
    /// attaching a false (empty) contract to its result — if
    /// `assertContract` signs off, the mechanism is broken.
    func test_assertContract_rejectsUndeclaredStructuralChange() throws {
        let before = project("Para\n\nAnother")
        let result = try EditingOps.changeHeadingLevel(2, at: 0, in: before)

        let lyingContract = EditContract(
            declaredActions: [],  // claims no change; blocks actually changed.
            postCursor: DocumentCursor(blockIndex: 0, inlineOffset: 0)
        )

        XCTExpectFailure("Contract lies — harness must reject it") {
            Invariants.assertContract(
                before: before,
                after: result.newProjection,
                contract: lyingContract
            )
        }
    }

    /// Leakage case: a contract that declares a change on one block
    /// but the actual edit touched a neighbor is the bug class the
    /// mechanism exists to catch. Forge this by editing block 0
    /// while claiming the change was at block 1.
    func test_assertContract_rejectsChangeOnWrongBlock() throws {
        let before = project("Para\n\nAnother")
        let result = try EditingOps.changeHeadingLevel(2, at: 0, in: before)

        let misplacedContract = EditContract(
            declaredActions: [.changeBlockKind(at: 2)],  // neighbor, not 0.
            postCursor: DocumentCursor(blockIndex: 0, inlineOffset: 0)
        )

        XCTExpectFailure("Contract names wrong block — harness must reject it") {
            Invariants.assertContract(
                before: before,
                after: result.newProjection,
                contract: misplacedContract
            )
        }
    }

    // MARK: - Table per-cell structural diff (Task 2)

    /// Positive: a real single-cell edit passes the new per-cell diff.
    /// This exercises the shape-preserved + neighbor-cells-unchanged path
    /// inside `assertContract` and proves the added structural check
    /// does not reject valid edits. The existing body-cell test covers
    /// the happy path too, but this one specifically verifies header
    /// neighbors + other-body-rows stay byte-identical.
    func test_assertContract_tableCellDiff_acceptsValidSingleCellEdit() throws {
        // 2x3 table (header + 2 body rows, 3 cols). Edit body[0][1] only.
        let md = """
        | A | B | C |
        | - | - | - |
        | a1 | b1 | c1 |
        | a2 | b2 | c2 |
        """
        let before = project(md)
        let result = try EditingOps.replaceTableCellInline(
            blockIndex: 0,
            at: .body(row: 0, col: 1),
            inline: [.text("NEW")],
            in: before
        )
        guard let contract = result.contract else {
            return XCTFail("replaceTableCellInline must populate contract")
        }
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        // Spot-check: body[0][1] changed, others unchanged.
        guard case .table(let header, _, let rows, _) =
                result.newProjection.document.blocks[0],
              case .table(let beforeHeader, _, let beforeRows, _) =
                before.document.blocks[0] else {
            return XCTFail("Both projections must expose .table at index 0")
        }
        XCTAssertEqual(header, beforeHeader, "Header must be untouched")
        XCTAssertEqual(rows[1], beforeRows[1], "Row 1 must be untouched")
        XCTAssertEqual(rows[0][0], beforeRows[0][0], "Cell [0,0] must be untouched")
        XCTAssertEqual(rows[0][2], beforeRows[0][2], "Cell [0,2] must be untouched")
        XCTAssertNotEqual(rows[0][1], beforeRows[0][1], "Cell [0,1] must have changed")
    }

    /// Negative: a contract that declares one cell changed while the
    /// after-projection has *two* cells changed must fail. Fabricate
    /// this by hand-mutating a copy of the Document so two cells
    /// differ from before, then declaring only one `.replaceTableCell`.
    /// The per-cell diff in `assertContract` should catch the undeclared
    /// second-cell change.
    func test_assertContract_tableCellDiff_rejectsCrossCellLeak() throws {
        let md = """
        | A | B |
        | - | - |
        | a1 | b1 |
        """
        let before = project(md)

        // Build a forged "after" document where TWO cells have changed.
        // Mimic what a buggy primitive might produce.
        var forgedDoc = before.document
        guard case .table(let header, let alignments, let rows, let raw) =
                forgedDoc.blocks[0] else {
            return XCTFail("Block 0 must be a table")
        }
        var newRows = rows
        newRows[0][0] = TableCell([.text("HACKED-1")])  // declared
        newRows[0][1] = TableCell([.text("HACKED-2")])  // undeclared leak
        forgedDoc.replaceBlock(
            at: 0,
            with: .table(header: header, alignments: alignments,
                         rows: newRows, raw: raw)
        )
        let forgedAfter = DocumentProjection(
            document: forgedDoc,
            bodyFont: bodyFont(),
            codeFont: codeFont()
        )

        // Declare only the first-cell change. The second change is the
        // leak the structural diff must catch.
        let lyingContract = EditContract(
            declaredActions: [.replaceTableCell(blockIndex: 0, rowIndex: 0, colIndex: 0)],
            postCursor: DocumentCursor(blockIndex: 0, inlineOffset: 0)
        )

        XCTExpectFailure("Cross-cell leak must be caught by per-cell structural diff") {
            Invariants.assertContract(
                before: before,
                after: forgedAfter,
                contract: lyingContract
            )
        }
    }

    /// Negative: shape changes (row count, column count, alignments) are
    /// not permitted by `.replaceTableCell`. A primitive that added a
    /// column while editing a cell is a shape-change bug; the contract
    /// must reject it.
    func test_assertContract_tableCellDiff_rejectsShapeChange() throws {
        let md = """
        | A | B |
        | - | - |
        | a1 | b1 |
        """
        let before = project(md)

        // Forge an "after" that grew from 2 to 3 columns.
        var forgedDoc = before.document
        guard case .table(let header, let alignments, let rows, let raw) =
                forgedDoc.blocks[0] else {
            return XCTFail("Block 0 must be a table")
        }
        let newHeader = header + [TableCell([.text("C")])]
        let newAlignments = alignments + [.none]
        let newRows = rows.map { $0 + [TableCell([.text("extra")])] }
        forgedDoc.replaceBlock(
            at: 0,
            with: .table(header: newHeader, alignments: newAlignments,
                         rows: newRows, raw: raw)
        )
        let forgedAfter = DocumentProjection(
            document: forgedDoc,
            bodyFont: bodyFont(),
            codeFont: codeFont()
        )

        // Declare only a body-cell edit. The added column must trip the
        // shape-preservation check.
        let lyingContract = EditContract(
            declaredActions: [.replaceTableCell(blockIndex: 0, rowIndex: 0, colIndex: 0)],
            postCursor: DocumentCursor(blockIndex: 0, inlineOffset: 0)
        )

        XCTExpectFailure("Shape change must be caught by table-cell structural diff") {
            Invariants.assertContract(
                before: before,
                after: forgedAfter,
                contract: lyingContract
            )
        }
    }

    // MARK: - Batch H: delete() core primitive contracts

    /// Path 1 of `delete()`: zero-length range is a no-op. Contract
    /// must declare no structural actions and pin the cursor at the
    /// no-op location.
    func test_delete_zeroLength_noOpContract() throws {
        let before = project("hello")
        let result = try EditingOps.delete(
            range: NSRange(location: 2, length: 0),
            in: before
        )

        guard let contract = result.contract else {
            return XCTFail("delete() zero-length path must populate contract")
        }
        XCTAssertTrue(
            contract.declaredActions.isEmpty,
            "Zero-length delete is a no-op: no structural actions"
        )
        XCTAssertEqual(
            contract.postCursor,
            DocumentCursor(blockIndex: 0, inlineOffset: 2)
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    /// Path 4 of `delete()`: single-block inner character delete.
    /// Contract declares `.modifyInline` on the touched block; kind
    /// is preserved.
    func test_delete_singleBlockInner_modifyInlineContract() throws {
        let before = project("First\n\nSecond\n\nThird")
        // Delete "ec" from "Second" (positions 8..10 inside "Second").
        // "First" is blocks[0] (5 chars), blank = blocks[1] (0 chars),
        // "Second" is blocks[2] starting at storage index 7.
        let result = try EditingOps.delete(
            range: NSRange(location: 8, length: 2),
            in: before
        )

        guard let contract = result.contract else {
            return XCTFail("delete() single-block path must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.modifyInline(blockIndex: 2)],
            "Inner-block delete declares modifyInline on the touched slot"
        )
        XCTAssertEqual(contract.postCursor.blockPath, [2])
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    /// Path 3 of `delete()`: full-select an atomic block (horizontal
    /// rule). The block is replaced with an empty paragraph — same
    /// slot position, different kind. Contract declares
    /// `.changeBlockKind`.
    func test_delete_atomicBlockFullSelect_changeBlockKindContract() throws {
        let before = project("intro\n\n---\n\noutro")
        // HR renders as a single attachment glyph. Find its span and
        // select the full block.
        let hrBlockIndex = before.document.blocks.firstIndex {
            if case .horizontalRule = $0 { return true }
            return false
        }
        guard let hrIdx = hrBlockIndex else {
            return XCTFail("Expected an HR in seeded document")
        }
        let hrSpan = before.blockSpans[hrIdx]

        let result = try EditingOps.delete(range: hrSpan, in: before)

        guard let contract = result.contract else {
            return XCTFail("delete() atomic-block path must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.changeBlockKind(at: hrIdx)],
            "Atomic-block full-select → paragraph is a slot-preserving kind change"
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )

        // Sanity: the post-edit block IS a paragraph (empty), not an HR.
        let afterBlock = result.newProjection.document.blocks[hrIdx]
        if case .paragraph(let inline) = afterBlock {
            XCTAssertTrue(
                inline.isEmpty,
                "Atomic-block delete produces an empty paragraph"
            )
        } else {
            XCTFail("Expected post-edit block to be a paragraph, got \(afterBlock)")
        }
    }

    // MARK: - Batch H: replace() core primitive contract

    /// `replace()` is single-block, single-line. Contract declares
    /// `.modifyInline` on the touched block.
    func test_replace_singleBlockInner_modifyInlineContract() throws {
        let before = project("First\n\nSecond\n\nThird")
        // "Second" starts at storage index 7. Replace "ec" (indices 8..10)
        // with "OO".
        let result = try EditingOps.replace(
            range: NSRange(location: 8, length: 2),
            with: "OO",
            in: before
        )

        guard let contract = result.contract else {
            return XCTFail("replace() must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.modifyInline(blockIndex: 2)]
        )
        XCTAssertEqual(contract.postCursor.blockPath, [2])
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )

        // Sanity: the resulting paragraph reads "SOOond".
        if case .paragraph(let inline) = result.newProjection.document.blocks[2] {
            let flat = inline.map {
                if case .text(let t) = $0 { return t } else { return "" }
            }.joined()
            XCTAssertEqual(flat, "SOOond")
        } else {
            XCTFail("Expected paragraph after replace")
        }
    }

    // MARK: - Batch H: insert() core-typing path contract

    /// The common typing fall-through in `insert()` (no newline, no
    /// FSM transition, no atomic-block creation). Contract declares
    /// `.modifyInline` on the touched block.
    func test_insert_typingFallThrough_modifyInlineContract() throws {
        let before = project("First\n\nSecond\n\nThird")
        // "Second" starts at storage index 7. Insert "X" after "S".
        let result = try EditingOps.insert(
            "X",
            at: 8,
            in: before
        )

        guard let contract = result.contract else {
            return XCTFail("insert() typing path must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.modifyInline(blockIndex: 2)]
        )
        XCTAssertEqual(contract.postCursor.blockPath, [2])
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )

        // Sanity: paragraph content is now "SXecond".
        if case .paragraph(let inline) = result.newProjection.document.blocks[2] {
            let flat = inline.map {
                if case .text(let t) = $0 { return t } else { return "" }
            }.joined()
            XCTAssertEqual(flat, "SXecond")
        } else {
            XCTFail("Expected paragraph after insert")
        }
    }

    /// Insert a multi-character string (still no newline) — same
    /// contract, different cursor position.
    func test_insert_multiCharString_modifyInlineContract() throws {
        let before = project("hello world")
        let result = try EditingOps.insert(" wonderful", at: 5, in: before)

        guard let contract = result.contract else {
            return XCTFail("insert() must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.modifyInline(blockIndex: 0)]
        )
        // Cursor at end of inserted string: index 5 + 10 = 15.
        XCTAssertEqual(contract.postCursor.blockPath, [0])
        XCTAssertEqual(contract.postCursor.inlineOffset, 15)
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    /// `replace()` inside a code block: promotion-to-diagram-language
    /// path still declares `.modifyInline` (the block stays a
    /// `.codeBlock` even if its language field changes).
    func test_replace_codeBlockInner_modifyInlineContract() throws {
        let before = project("```\nfoo\n```")
        // The code block is blocks[0]. "foo" is content; replace "o" at
        // index 1 inside the content with "X".
        // Storage layout (approx): content starts at the fence's inner
        // offset. Find a plain offset inside "foo".
        guard case .codeBlock = before.document.blocks[0] else {
            return XCTFail("Expected a code block as block[0]")
        }
        let span = before.blockSpans[0]
        // Pick an interior storage offset — second char of "foo".
        let target = span.location + 1
        let result = try EditingOps.replace(
            range: NSRange(location: target, length: 1),
            with: "X",
            in: before
        )

        guard let contract = result.contract else {
            return XCTFail("replace() must populate contract on code block")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.modifyInline(blockIndex: 0)]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    // MARK: - Batch H part 4: insert() Return-split dispatch paths

    /// Return on a blank line produces a second blank line below. The
    /// pre-edit blankLine is preserved; a fresh blankLine is inserted
    /// at `blockIndex + 1`.
    func test_insert_blankLineReturnDoubling_insertBlockContract() throws {
        // Doc: "First\n\n\n\nSecond" → ["First", blankLine, "Second"].
        // Actually the blank separator between blocks is implicit —
        // let's construct a doc whose block[1] is an explicit blankLine
        // by using the double-newline pattern the parser emits.
        let before = project("First\n\n\n\nSecond")
        // Locate a blankLine block.
        guard let blIdx = before.document.blocks.firstIndex(where: {
            if case .blankLine = $0 { return true } else { return false }
        }) else {
            return XCTFail("Expected at least one .blankLine in the doc")
        }
        let span = before.blockSpans[blIdx]
        // Return at the blankLine's only position (span.location).
        let result = try EditingOps.insert("\n", at: span.location, in: before)

        guard let contract = result.contract else {
            return XCTFail("Return on blankLine must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.insertBlock(at: blIdx + 1)]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        // Post-edit: block count went up by 1, and the inserted slot
        // is a blankLine.
        XCTAssertEqual(
            result.newProjection.document.blocks.count,
            before.document.blocks.count + 1
        )
        if case .blankLine = result.newProjection.document.blocks[blIdx + 1] {
            // OK
        } else {
            XCTFail("Inserted slot should be a blankLine")
        }
    }

    /// Return in the middle of a paragraph splits it into two halves
    /// with a blankLine separator. Three blocks out, two inserts
    /// declared (plus the existing paragraph modified to the "before"
    /// half).
    func test_insert_paragraphReturnMidWord_splitShapeContract() throws {
        let before = project("hello world")
        // Return between "hello" and " world" at storage index 5.
        let result = try EditingOps.insert("\n", at: 5, in: before)

        guard let contract = result.contract else {
            return XCTFail("Return on paragraph must populate contract")
        }
        // "hello" and "world" are both non-empty (well, " world" has a
        // leading space but not empty) → case (false, false) →
        // 3-block shape.
        XCTAssertEqual(
            contract.declaredActions,
            [
                .modifyInline(blockIndex: 0),
                .insertBlock(at: 1),
                .insertBlock(at: 2)
            ]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        XCTAssertEqual(
            result.newProjection.document.blocks.count,
            before.document.blocks.count + 2
        )
    }

    /// Return at the start of a paragraph: "before" half empty →
    /// paragraph→blankLine kind change at `blockIndex`, fresh
    /// paragraph inserted at `blockIndex + 1`.
    func test_insert_paragraphReturnAtStart_changeKindContract() throws {
        let before = project("hello")
        // Return at index 0 (start of paragraph).
        let result = try EditingOps.insert("\n", at: 0, in: before)

        guard let contract = result.contract else {
            return XCTFail("Return on paragraph must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [
                .changeBlockKind(at: 0),
                .insertBlock(at: 1)
            ]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        // Block 0 is now a blankLine; block 1 is the paragraph with "hello".
        if case .blankLine = result.newProjection.document.blocks[0] {
            // OK
        } else {
            XCTFail("Expected blankLine at index 0")
        }
    }

    /// Return in the middle of a heading splits into (heading, paragraph).
    /// Heading's suffix shortens → `.modifyInline`; a fresh paragraph
    /// is inserted at `blockIndex + 1`.
    func test_insert_headingReturnMid_modifyInlineThenInsert() throws {
        let before = project("# Hello World")
        // Find the heading's span.
        guard case .heading = before.document.blocks[0] else {
            return XCTFail("Expected heading at block[0]")
        }
        // Return between "Hello" and " World". Rendered offset 5 in
        // the heading (the "# " marker is not in rendered coords).
        let span = before.blockSpans[0]
        let result = try EditingOps.insert("\n", at: span.location + 5, in: before)

        guard let contract = result.contract else {
            return XCTFail("Return on heading must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [
                .modifyInline(blockIndex: 0),
                .insertBlock(at: 1)
            ]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        // Block 0 is still a heading; block 1 is a paragraph with " World".
        if case .heading = result.newProjection.document.blocks[0] {
            // OK
        } else {
            XCTFail("Block 0 should remain a heading")
        }
        if case .paragraph = result.newProjection.document.blocks[1] {
            // OK
        } else {
            XCTFail("Block 1 should be a paragraph")
        }
    }

    /// Return at the start of an HR (atomic block) inserts an empty
    /// paragraph BEFORE the HR. The HR preserves its content; the
    /// "inserted" slot is `blockIndex + 1` in post-edit coordinates
    /// (the HR's new slot after being shifted down).
    func test_insert_returnBeforeAtomicHR_insertBlockContract() throws {
        let before = project("First\n\n---\n\nSecond")
        // Find the HR block.
        guard let hrIdx = before.document.blocks.firstIndex(where: {
            if case .horizontalRule = $0 { return true } else { return false }
        }) else {
            return XCTFail("Expected an HR block")
        }
        let hrSpan = before.blockSpans[hrIdx]
        // Return at the start of the HR → paragraph goes BEFORE.
        let result = try EditingOps.insert("\n", at: hrSpan.location, in: before)

        guard let contract = result.contract else {
            return XCTFail("Return on atomic block must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.insertBlock(at: hrIdx + 1)]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    /// Multi-line paste into a paragraph. Paste of "\na\nb" at end of
    /// "hello" → paragraph + two new paragraph blocks. Delta-based
    /// contract: `.replaceBlock` + N `.insertBlock`s.
    func test_insert_pasteMultilineIntoParagraph_contractMatches() throws {
        let before = project("hello")
        // Paste "\nfoo\n\nbar" at position 5 (end of "hello"). The parser
        // reads this as: soft-break after hello, then "foo", blank line,
        // then "bar" — producing some multi-block output.
        let result = try EditingOps.insert("\nfoo\n\nbar", at: 5, in: before)

        guard let contract = result.contract else {
            return XCTFail("Paragraph paste must populate contract")
        }
        // The first declared action must be `.replaceBlock(at: 0)`.
        XCTAssertEqual(
            contract.declaredActions.first,
            .replaceBlock(at: 0),
            "First action should target the paragraph being pasted into"
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        // Block count grew (multi-line paste always adds blocks).
        XCTAssertGreaterThan(
            result.newProjection.document.blocks.count,
            before.document.blocks.count
        )
    }

    /// Multi-line paste into a list item. `pasteIntoList` produces one
    /// `.list` block (items array grew) — single `.replaceBlock`.
    func test_insert_pasteMultilineIntoList_replaceBlockContract() throws {
        let before = project("- first\n- second")
        guard case .list = before.document.blocks[0] else {
            return XCTFail("Expected a list at block[0]")
        }
        let span = before.blockSpans[0]
        // Paste "A\nB" somewhere inside the first item's inline content.
        let cursor = span.location + 4  // inside "first"
        let result = try EditingOps.insert("A\nB", at: cursor, in: before)

        guard let contract = result.contract else {
            return XCTFail("List paste must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.replaceBlock(at: 0)]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        // Still exactly one .list block post-edit.
        XCTAssertEqual(
            result.newProjection.document.blocks.count,
            before.document.blocks.count
        )
    }

    /// Multi-line paste into a blockquote line. One `.blockquote` block
    /// out (lines array grew) — single `.replaceBlock`.
    func test_insert_pasteMultilineIntoBlockquote_replaceBlockContract() throws {
        let before = project("> original quote")
        guard case .blockquote = before.document.blocks[0] else {
            return XCTFail("Expected a blockquote at block[0]")
        }
        let span = before.blockSpans[0]
        // Paste "A\nB" inside the line's inline content.
        let cursor = span.location + 5  // inside "original"
        let result = try EditingOps.insert("A\nB", at: cursor, in: before)

        guard let contract = result.contract else {
            return XCTFail("Blockquote paste must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.replaceBlock(at: 0)]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        XCTAssertEqual(
            result.newProjection.document.blocks.count,
            before.document.blocks.count
        )
    }

    /// Multi-line paste into a heading. Heading becomes paragraph (kind
    /// change via `.replaceBlock`), and additional blocks are appended.
    func test_insert_pasteMultilineIntoHeading_contractMatches() throws {
        let before = project("# Hello")
        guard case .heading = before.document.blocks[0] else {
            return XCTFail("Expected a heading at block[0]")
        }
        let span = before.blockSpans[0]
        // Paste "A\n\nB" — a hard paragraph break — at offset 5 (end of
        // "Hello" rendered). A single "\n" in markdown is a soft break
        // (stays in one paragraph), which would collapse to a single
        // replaceBlock with delta=0; we want to cover the growth case.
        let result = try EditingOps.insert("A\n\nB", at: span.location + 5, in: before)

        guard let contract = result.contract else {
            return XCTFail("Heading paste must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions.first,
            .replaceBlock(at: 0),
            "First action should be the heading-slot replaceBlock"
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        // Heading paste with a hard break should grow the block count
        // (converts the heading to a paragraph + adds pasted tail blocks).
        XCTAssertGreaterThan(
            result.newProjection.document.blocks.count,
            before.document.blocks.count
        )
    }

    /// Return in the middle of a list item splits that item into two
    /// items within the same `.list` block. The block index / kind /
    /// count are unchanged; the list's items array grew by one.
    /// Contract: `.replaceBlock(at: blockIndex)`.
    func test_insert_listReturnMidItem_replaceBlockContract() throws {
        let before = project("- first item\n- second item")
        guard case .list = before.document.blocks[0] else {
            return XCTFail("Expected a list at block[0]")
        }
        let span = before.blockSpans[0]
        // Return in the middle of "first item" — at offset 5 (between
        // "first" and " item"). The rendered list content starts at
        // span.location; the first item's content starts after the
        // marker prefix. Pick a safe interior offset: the parser emits
        // the marker characters in the rendered string, so splitting at
        // storage offset `span.location + 7` (just after "- first") is
        // inside the first item's inline content.
        let cursor = span.location + 7
        let result = try EditingOps.insert("\n", at: cursor, in: before)

        guard let contract = result.contract else {
            return XCTFail("List Return mid-item must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.replaceBlock(at: 0)]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        // Post-edit: still one .list block, items count went up by one.
        XCTAssertEqual(
            result.newProjection.document.blocks.count,
            before.document.blocks.count
        )
        if case .list(let newItems, _) = result.newProjection.document.blocks[0],
           case .list(let oldItems, _) = before.document.blocks[0] {
            XCTAssertEqual(newItems.count, oldItems.count + 1)
        } else {
            XCTFail("Expected list at block[0] post-edit")
        }
    }

    /// Return in the middle of a blockquote line splits that line into
    /// two lines within the same `.blockquote` block.
    /// Contract: `.replaceBlock(at: blockIndex)`.
    func test_insert_blockquoteReturnMidLine_replaceBlockContract() throws {
        let before = project("> first quote line")
        guard case .blockquote = before.document.blocks[0] else {
            return XCTFail("Expected a blockquote at block[0]")
        }
        let span = before.blockSpans[0]
        // Return somewhere inside the inline content. Offset 5 into the
        // rendered span is safely inside "first quote line".
        let cursor = span.location + 5
        let result = try EditingOps.insert("\n", at: cursor, in: before)

        guard let contract = result.contract else {
            return XCTFail("Blockquote Return mid-line must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.replaceBlock(at: 0)]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        // Post-edit: still one .blockquote block, lines count +1.
        if case .blockquote(let newLines) = result.newProjection.document.blocks[0],
           case .blockquote(let oldLines) = before.document.blocks[0] {
            XCTAssertEqual(newLines.count, oldLines.count + 1)
        } else {
            XCTFail("Expected blockquote at block[0] post-edit")
        }
    }

    /// Return at the end of a code block whose content ends with a
    /// trailing newline exits the code block: content is trimmed and
    /// a fresh empty paragraph is inserted at `blockIndex + 1`.
    /// Contract: `.modifyInline` on the code block + `.insertBlock`.
    func test_insert_codeBlockReturnOnBlank_exitContract() throws {
        // Construct a code block whose content ends with "\n" — the
        // user just pressed Return once to create a blank trailing line
        // inside the code block. The "second Return" is what this test
        // simulates.
        let before = project("```\nfoo\n\n```\n")
        guard case .codeBlock(_, let content, _) = before.document.blocks[0] else {
            return XCTFail("Expected code block at block[0]")
        }
        XCTAssertTrue(content.hasSuffix("\n"),
                      "Precondition: content must end with '\\n' for exit path")
        // Cursor at the end of content inside the code block.
        let span = before.blockSpans[0]
        let endOfContent = span.location + content.count
        let result = try EditingOps.insert("\n", at: endOfContent, in: before)

        guard let contract = result.contract else {
            return XCTFail("Code-block exit must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [
                .modifyInline(blockIndex: 0),
                .insertBlock(at: 1)
            ]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        // Block 0 is still a code block; block 1 is a fresh paragraph.
        if case .codeBlock = result.newProjection.document.blocks[0] {
            // OK
        } else {
            XCTFail("Block 0 should remain a code block")
        }
        if case .paragraph = result.newProjection.document.blocks[1] {
            // OK
        } else {
            XCTFail("Block 1 should be a paragraph")
        }
    }

    /// Typed character just past an HR (offset != 0) inserts a
    /// paragraph AFTER the HR. Contract declares insertBlock at the
    /// new paragraph's post-edit slot.
    func test_insert_typeAfterAtomicHR_insertBlockContract() throws {
        let before = project("First\n\n---\n\nSecond")
        guard let hrIdx = before.document.blocks.firstIndex(where: {
            if case .horizontalRule = $0 { return true } else { return false }
        }) else {
            return XCTFail("Expected an HR block")
        }
        let hrSpan = before.blockSpans[hrIdx]
        // Type "x" at the end of the HR (offset > 0 → paragraph AFTER).
        let result = try EditingOps.insert("x", at: hrSpan.location + hrSpan.length, in: before)

        guard let contract = result.contract else {
            return XCTFail("Typing on atomic block must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.insertBlock(at: hrIdx + 1)]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
    }

    // MARK: - Batch H part 6

    /// Multi-line paste AFTER an atomic block (HR). The atomic block
    /// stays at `blockIndex`; N sibling blocks are spliced in after it.
    /// Contract: `.replaceBlock(at: blockIndex)` + N × `.insertBlock`
    /// (delta-based, same shape as paragraph/heading multi-line paste).
    func test_insert_atomicMultiLinePasteAfter_contractMatches() throws {
        let before = project("---\n\n")
        guard case .horizontalRule = before.document.blocks[0] else {
            return XCTFail("Expected an HR at block[0]")
        }
        let hrSpan = before.blockSpans[0]
        // Paste 2 paragraph blocks after the HR.
        let result = try EditingOps.insert(
            "first\n\nsecond",
            at: hrSpan.location + hrSpan.length,
            in: before
        )

        guard let contract = result.contract else {
            return XCTFail("atomic multi-line paste must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions.first,
            .replaceBlock(at: 0),
            "First action should be the atomic-slot replaceBlock"
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        XCTAssertGreaterThan(
            result.newProjection.document.blocks.count,
            before.document.blocks.count
        )
    }

    /// Multi-line paste BEFORE an atomic block (HR). Paragraph siblings
    /// are spliced in at slot 0; the atomic block shifts down. Contract:
    /// delta-based `.replaceBlock + N × .insertBlock`.
    func test_insert_atomicMultiLinePasteBefore_contractMatches() throws {
        let before = project("---\n\n")
        guard case .horizontalRule = before.document.blocks[0] else {
            return XCTFail("Expected an HR at block[0]")
        }
        let hrSpan = before.blockSpans[0]
        // Paste at offset 0 of the HR rendered span: insertBefore path.
        let result = try EditingOps.insert(
            "first\n\nsecond",
            at: hrSpan.location,
            in: before
        )

        guard let contract = result.contract else {
            return XCTFail("atomic multi-line paste must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions.first,
            .replaceBlock(at: 0),
            "First action should be the atomic-slot replaceBlock"
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        XCTAssertGreaterThan(
            result.newProjection.document.blocks.count,
            before.document.blocks.count
        )
    }

    /// Typing a single character into an HTML block is an in-place inline
    /// edit — the block stays an `.htmlBlock` with spliced raw content.
    /// Contract: `.modifyInline(blockIndex: blockIndex)` (the typing
    /// fall-through path in `insert()`).
    func test_insert_htmlBlockTypeChar_modifyInlineContract() throws {
        let before = project("<div>hello</div>\n")
        guard case .htmlBlock = before.document.blocks[0] else {
            return XCTFail("Expected an htmlBlock at block[0]")
        }
        let span = before.blockSpans[0]
        // Type "x" at offset 5 inside "<div>hello</div>".
        let result = try EditingOps.insert("x", at: span.location + 5, in: before)

        guard let contract = result.contract else {
            return XCTFail("htmlBlock typing must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.modifyInline(blockIndex: 0)]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        // Block count unchanged, still an htmlBlock.
        XCTAssertEqual(
            result.newProjection.document.blocks.count,
            before.document.blocks.count
        )
        guard case .htmlBlock = result.newProjection.document.blocks[0] else {
            return XCTFail("Expected htmlBlock to remain after typing")
        }
    }

    // MARK: - Batch H part 7: mergeAdjacentBlocks / delete multi-block

    /// Deleting a selection that spans exactly two adjacent paragraphs
    /// produces one merged paragraph. Contract: `.replaceBlock(at: 0)`
    /// + one `.mergeAdjacent(firstIndex: 0)` (delta = -1).
    func test_delete_crossBlockPairMerge_contractMatches() throws {
        let before = project("hello\n\nworld")
        XCTAssertEqual(before.document.blocks.count, 3)
        let pSpan = before.blockSpans[0]
        let wSpan = before.blockSpans[2]
        // Delete from "ello" end of para1 through "wo" start of para2,
        // consuming the blankLine between them. That's a selection over
        // 3 blocks: [paragraph, blankLine, paragraph].
        let range = NSRange(
            location: pSpan.location + 1,
            length: (wSpan.location + 2) - (pSpan.location + 1)
        )
        let result = try EditingOps.delete(range: range, in: before)

        guard let contract = result.contract else {
            return XCTFail("cross-block delete must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions.first,
            .replaceBlock(at: 0),
            "First action should be the merge-surface replaceBlock"
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        // 3 blocks → 1 block.
        XCTAssertEqual(result.newProjection.document.blocks.count, 1)
    }

    /// Deleting a selection that spans 4 blocks (para, blank, para, para)
    /// reduces to one paragraph. Contract shape carries enough
    /// `.mergeAdjacent` declarations to account for the delta.
    func test_delete_crossBlockMultiMerge_contractMatches() throws {
        let before = project("first\n\nsecond\n\nthird")
        XCTAssertEqual(before.document.blocks.count, 5)
        let firstSpan = before.blockSpans[0]
        let lastSpan = before.blockSpans[4]
        // Select from interior of "first" through interior of "third".
        let range = NSRange(
            location: firstSpan.location + 2,
            length: (lastSpan.location + 2) - (firstSpan.location + 2)
        )
        let result = try EditingOps.delete(range: range, in: before)

        guard let contract = result.contract else {
            return XCTFail("cross-block delete must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions.first,
            .replaceBlock(at: 0),
            "First action should be the merge-surface replaceBlock"
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        // 5 blocks → 1 block.
        XCTAssertEqual(result.newProjection.document.blocks.count, 1)
    }

    /// Return inside an HTML block embeds a newline in the raw HTML
    /// rather than splitting the block. Contract: `.modifyInline`.
    func test_insert_htmlBlockReturn_modifyInlineContract() throws {
        let before = project("<div>hello</div>\n")
        guard case .htmlBlock = before.document.blocks[0] else {
            return XCTFail("Expected an htmlBlock at block[0]")
        }
        let span = before.blockSpans[0]
        let result = try EditingOps.insert("\n", at: span.location + 5, in: before)

        guard let contract = result.contract else {
            return XCTFail("htmlBlock Return must populate contract")
        }
        XCTAssertEqual(
            contract.declaredActions,
            [.modifyInline(blockIndex: 0)]
        )
        Invariants.assertContract(
            before: before,
            after: result.newProjection,
            contract: contract
        )
        XCTAssertEqual(
            result.newProjection.document.blocks.count,
            before.document.blocks.count
        )
    }
}
