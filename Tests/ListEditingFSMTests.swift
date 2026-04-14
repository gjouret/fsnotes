//
//  ListEditingFSMTests.swift
//  FSNotesTests
//
//  Comprehensive tests for the List Editing FSM.
//
//  Tests cover:
//  1. FSM transition table (pure function tests)
//  2. State detection from DocumentProjection
//  3. Tree manipulation: indent, unindent, exit
//  4. Return on empty item (exit/unindent)
//  5. Delete at home position
//  6. Depth-based bullet variation
//  7. Round-trip after structural operations
//

import XCTest
@testable import FSNotes

class ListEditingFSMTests: XCTestCase {

    // MARK: - Helpers

    private func bodyFont() -> PlatformFont { PlatformFont.systemFont(ofSize: 14) }
    private func codeFont() -> PlatformFont { PlatformFont.monospacedSystemFont(ofSize: 13, weight: .regular) }

    private func makeProjection(_ markdown: String) -> DocumentProjection {
        let doc = MarkdownParser.parse(markdown)
        return DocumentProjection(
            document: doc,
            bodyFont: bodyFont(),
            codeFont: codeFont()
        )
    }

    // MARK: - 1. FSM transition table (pure)

    func test_bodyText_tab_noOp() {
        let t = ListEditingFSM.transition(state: .bodyText, action: .tab)
        XCTAssertEqual(t, .noOp)
    }

    func test_bodyText_shiftTab_noOp() {
        let t = ListEditingFSM.transition(state: .bodyText, action: .shiftTab)
        XCTAssertEqual(t, .noOp)
    }

    func test_bodyText_returnKey_noOp() {
        let t = ListEditingFSM.transition(state: .bodyText, action: .returnKey)
        XCTAssertEqual(t, .noOp)
    }

    func test_depth0_tab_withPrevSibling_indent() {
        let t = ListEditingFSM.transition(
            state: .listItem(depth: 0, hasPreviousSibling: true),
            action: .tab
        )
        XCTAssertEqual(t, .indent)
    }

    func test_depth0_tab_noPrevSibling_noOp() {
        let t = ListEditingFSM.transition(
            state: .listItem(depth: 0, hasPreviousSibling: false),
            action: .tab
        )
        XCTAssertEqual(t, .noOp)
    }

    func test_depth0_shiftTab_exit() {
        let t = ListEditingFSM.transition(
            state: .listItem(depth: 0, hasPreviousSibling: false),
            action: .shiftTab
        )
        XCTAssertEqual(t, .exitToBody)
    }

    func test_depth0_deleteAtHome_exit() {
        let t = ListEditingFSM.transition(
            state: .listItem(depth: 0, hasPreviousSibling: true),
            action: .deleteAtHome
        )
        XCTAssertEqual(t, .exitToBody)
    }

    func test_depth0_returnKey_newItem() {
        let t = ListEditingFSM.transition(
            state: .listItem(depth: 0, hasPreviousSibling: false),
            action: .returnKey
        )
        XCTAssertEqual(t, .newItem)
    }

    func test_depth0_returnOnEmpty_exit() {
        let t = ListEditingFSM.transition(
            state: .listItem(depth: 0, hasPreviousSibling: false),
            action: .returnOnEmpty
        )
        XCTAssertEqual(t, .exitToBody)
    }

    func test_depth1_tab_withPrevSibling_indent() {
        let t = ListEditingFSM.transition(
            state: .listItem(depth: 1, hasPreviousSibling: true),
            action: .tab
        )
        XCTAssertEqual(t, .indent)
    }

    func test_depth1_tab_noPrevSibling_noOp() {
        let t = ListEditingFSM.transition(
            state: .listItem(depth: 1, hasPreviousSibling: false),
            action: .tab
        )
        XCTAssertEqual(t, .noOp)
    }

    func test_depth1_shiftTab_unindent() {
        let t = ListEditingFSM.transition(
            state: .listItem(depth: 1, hasPreviousSibling: false),
            action: .shiftTab
        )
        XCTAssertEqual(t, .unindent)
    }

    func test_depth1_deleteAtHome_unindent() {
        let t = ListEditingFSM.transition(
            state: .listItem(depth: 1, hasPreviousSibling: true),
            action: .deleteAtHome
        )
        XCTAssertEqual(t, .unindent)
    }

    func test_depth1_returnKey_newItem() {
        let t = ListEditingFSM.transition(
            state: .listItem(depth: 1, hasPreviousSibling: false),
            action: .returnKey
        )
        XCTAssertEqual(t, .newItem)
    }

    func test_depth1_returnOnEmpty_unindent() {
        let t = ListEditingFSM.transition(
            state: .listItem(depth: 1, hasPreviousSibling: false),
            action: .returnOnEmpty
        )
        XCTAssertEqual(t, .unindent)
    }

    func test_depth2_shiftTab_unindent() {
        let t = ListEditingFSM.transition(
            state: .listItem(depth: 2, hasPreviousSibling: false),
            action: .shiftTab
        )
        XCTAssertEqual(t, .unindent)
    }

    func test_depth2_returnOnEmpty_unindent() {
        let t = ListEditingFSM.transition(
            state: .listItem(depth: 2, hasPreviousSibling: false),
            action: .returnOnEmpty
        )
        XCTAssertEqual(t, .unindent)
    }

    // MARK: - 2. State detection

    func test_stateDetection_bodyText() {
        let proj = makeProjection("Hello world\n")
        // Cursor in the paragraph.
        let state = ListEditingFSM.detectState(storageIndex: 3, in: proj)
        XCTAssertEqual(state, .bodyText)
    }

    func test_stateDetection_firstItem_depth0() {
        let proj = makeProjection("- alpha\n- beta\n")
        // rendered: "￼alpha\n￼beta" — cursor in "alpha" inline (offset 1)
        let state = ListEditingFSM.detectState(storageIndex: 1, in: proj)
        XCTAssertEqual(state, .listItem(depth: 0, hasPreviousSibling: false))
    }

    func test_stateDetection_secondItem_depth0() {
        let proj = makeProjection("- alpha\n- beta\n")
        // rendered: "￼alpha\n￼beta"
        // "￼alpha" = 6 chars, "\n" = 1, "￼beta" prefix = 1
        // inline of second item starts at 6 + 1 + 1 = 8
        let state = ListEditingFSM.detectState(storageIndex: 8, in: proj)
        XCTAssertEqual(state, .listItem(depth: 0, hasPreviousSibling: true))
    }

    func test_stateDetection_nestedItem_depth1() {
        let proj = makeProjection("- parent\n  - child\n")
        // rendered: "￼parent\n￼child"
        // "￼parent" = 1 + 6 = 7, "\n" = 1, child prefix = 1 (attachment)
        // child inline starts at 7 + 1 + 1 = 9
        let state = ListEditingFSM.detectState(storageIndex: 9, in: proj)
        XCTAssertEqual(state, .listItem(depth: 1, hasPreviousSibling: false))
    }

    // MARK: - 3. Tree manipulation: indent

    func test_indent_secondItem_becomesChildOfFirst() {
        let proj = makeProjection("- alpha\n- beta\n")
        // Indent the second item.
        // rendered: "￼alpha\n￼beta" — "beta" inline starts at 6 + 1 + 1 = 8
        let result = try! EditingOps.indentListItem(at: 8, in: proj)
        let newDoc = result.newProjection.document
        guard case .list(let items, _) = newDoc.blocks[0] else {
            XCTFail("Expected list block"); return
        }
        // After indent: one top-level item with one child.
        XCTAssertEqual(items.count, 1, "Should have one top-level item")
        XCTAssertEqual(items[0].children.count, 1, "First item should have one child")
        XCTAssertEqual(items[0].children[0].inline, [.text("beta")])
    }

    func test_indent_firstItem_fails() {
        let proj = makeProjection("- alpha\n- beta\n")
        // Try to indent the first item (no previous sibling).
        // alpha inline starts at prefix 1, so offset 1 is inside alpha.
        XCTAssertThrowsError(try EditingOps.indentListItem(at: 1, in: proj))
    }

    func test_indent_roundTrip() {
        let proj = makeProjection("- alpha\n- beta\n")
        // beta inline starts at 8
        let result = try! EditingOps.indentListItem(at: 8, in: proj)
        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        // After indenting, beta should be a child of alpha.
        XCTAssertTrue(serialized.contains("  - beta"), "Serialized should have indented beta: \(serialized)")
    }

    // MARK: - 4. Tree manipulation: unindent

    func test_unindent_childItem_becomesTopLevel() {
        let proj = makeProjection("- alpha\n  - beta\n")
        // "￼alpha\n￼beta" — alpha = 1 + 5 = 6, "\n" = 1, child prefix = 1
        // beta inline starts at 6 + 1 + 1 = 8
        let result = try! EditingOps.unindentListItem(at: 8, in: proj)
        let newDoc = result.newProjection.document
        guard case .list(let items, _) = newDoc.blocks[0] else {
            XCTFail("Expected list block"); return
        }
        XCTAssertEqual(items.count, 2, "Should have two top-level items")
        XCTAssertEqual(items[0].children.count, 0, "First item should have no children")
        XCTAssertEqual(items[1].inline, [.text("beta")])
    }

    func test_unindent_topLevel_throws() {
        let proj = makeProjection("- alpha\n- beta\n")
        // alpha is at depth 0. Inline starts at 1.
        XCTAssertThrowsError(try EditingOps.unindentListItem(at: 1, in: proj))
    }

    func test_unindent_roundTrip() {
        let proj = makeProjection("- alpha\n  - beta\n")
        // beta inline starts at 8
        let result = try! EditingOps.unindentListItem(at: 8, in: proj)
        let serialized = MarkdownSerializer.serialize(result.newProjection.document)
        // After unindent, beta is top-level.
        XCTAssertTrue(serialized.contains("- alpha\n"), "Should have alpha at top level")
        XCTAssertTrue(serialized.contains("- beta\n"), "Should have beta at top level")
    }

    // MARK: - 5. Exit list item

    func test_exit_singleItem_becomesParagraph() {
        let proj = makeProjection("- hello\n")
        // "￼hello" — inline starts at 1
        let result = try! EditingOps.exitListItem(at: 1, in: proj)
        let newDoc = result.newProjection.document
        // The list should be gone; replaced with a paragraph.
        XCTAssertTrue(newDoc.blocks.contains { if case .paragraph = $0 { return true }; return false },
                      "Should have a paragraph after exit")
        XCTAssertFalse(newDoc.blocks.contains { if case .list = $0 { return true }; return false },
                       "List should be removed when last item exits")
    }

    func test_exit_secondItem_listRemains() {
        let proj = makeProjection("- alpha\n- beta\n")
        // Exit "beta" (second item). inline at 6 + 1 + 1 = 8.
        let result = try! EditingOps.exitListItem(at: 8, in: proj)
        let newDoc = result.newProjection.document
        // alpha stays in a list, beta becomes a paragraph.
        XCTAssertTrue(newDoc.blocks.contains { if case .list = $0 { return true }; return false },
                      "List should remain with alpha")
        XCTAssertTrue(newDoc.blocks.contains {
            if case .paragraph(let inl) = $0, inl == [.text("beta")] { return true }; return false
        }, "beta should be a paragraph")
    }

    func test_exit_emptyItem_becomesEmptyParagraph() {
        // Create a projection with an empty list item.
        let doc = Document(blocks: [
            .list(items: [
                ListItem(indent: "", marker: "-", afterMarker: " ", inline: [], children: [])
            ])
        ])
        let proj = DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
        // Inline content starts at prefix length = 1 (attachment only)
        let result = try! EditingOps.exitListItem(at: 1, in: proj)
        let newDoc = result.newProjection.document
        // Exiting an empty list item must produce an empty .paragraph, NOT
        // a .blankLine. A .blankLine renders as a zero-length span with no
        // paragraph style applied, so the cursor inherits the surrounding
        // list's hanging indent from neighboring attributes. An empty
        // paragraph gets a fresh zero-indent paragraph style from the
        // renderer so the cursor sits at the left margin.
        XCTAssertTrue(newDoc.blocks.contains {
            if case .paragraph(let inline) = $0, inline.isEmpty { return true }
            return false
        }, "Empty item exit should produce an empty paragraph, not a blankLine")
        XCTAssertFalse(newDoc.blocks.contains {
            if case .blankLine = $0 { return true }; return false
        }, "Empty item exit must not produce a blankLine")
    }

    // MARK: - 6. Return on empty item

    func test_returnOnEmpty_depth0_exits() {
        let doc = Document(blocks: [
            .list(items: [
                ListItem(indent: "", marker: "-", afterMarker: " ", inline: [.text("keep")], children: []),
                ListItem(indent: "", marker: "-", afterMarker: " ", inline: [], children: [])
            ])
        ])
        let proj = DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
        // Second item (empty) — find its inline position.
        // "￼keep" = 1 + 4 = 5, "\n" = 1, second prefix = 1
        // inline of empty second item starts at 5 + 1 + 1 = 7
        let result = try! EditingOps.returnOnEmptyListItem(at: 7, in: proj)
        let newDoc = result.newProjection.document
        // The empty item should have exited (depth 0 → exitToBody).
        XCTAssertFalse(newDoc.blocks.isEmpty)
    }

    func test_returnOnEmpty_depth1_unindents() {
        let doc = Document(blocks: [
            .list(items: [
                ListItem(indent: "", marker: "-", afterMarker: " ", inline: [.text("parent")], children: [
                    ListItem(indent: "  ", marker: "-", afterMarker: " ", inline: [], children: [])
                ])
            ])
        ])
        let proj = DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
        // "￼parent\n￼" — parent prefix = 1 (attachment), text = 6, "\n" = 1,
        // child prefix = 1 (attachment), inline empty.
        // child inline starts at 1 + 6 + 1 + 1 = 9
        let result = try! EditingOps.returnOnEmptyListItem(at: 9, in: proj)
        let newDoc = result.newProjection.document
        // The empty nested item should have been unindented (depth 1 → unindent).
        guard case .list(let items, _) = newDoc.blocks[0] else {
            XCTFail("Expected list block"); return
        }
        // Should now have 2 top-level items (parent + the unindented empty item).
        XCTAssertEqual(items.count, 2, "Unindent should create 2 top-level items")
        XCTAssertEqual(items[0].children.count, 0, "Parent should have no children after unindent")
    }

    // MARK: - 7. Depth-based bullet variation

    func test_visualBullet_depth0_bullet() {
        XCTAssertEqual(ListRenderer.visualBullet(for: "-", depth: 0), "•")
    }

    func test_visualBullet_depth1_whiteBullet() {
        XCTAssertEqual(ListRenderer.visualBullet(for: "-", depth: 1), "◦")
    }

    func test_visualBullet_depth2_blackSquare() {
        XCTAssertEqual(ListRenderer.visualBullet(for: "*", depth: 2), "▪")
    }

    func test_visualBullet_depth3_whiteSquare() {
        XCTAssertEqual(ListRenderer.visualBullet(for: "+", depth: 3), "▫")
    }

    func test_visualBullet_depth4_cyclesBack() {
        XCTAssertEqual(ListRenderer.visualBullet(for: "-", depth: 4), "•")
    }

    func test_visualBullet_ordered_unchanged() {
        XCTAssertEqual(ListRenderer.visualBullet(for: "1.", depth: 0), "1.")
        XCTAssertEqual(ListRenderer.visualBullet(for: "2)", depth: 1), "2)")
    }

    // MARK: - 8. isAtHomePosition

    func test_isAtHomePosition_true() {
        let proj = makeProjection("- hello\n")
        // "￼hello" — inline starts at 1
        XCTAssertTrue(ListEditingFSM.isAtHomePosition(storageIndex: 1, in: proj))
    }

    func test_isAtHomePosition_false_midWord() {
        let proj = makeProjection("- hello\n")
        // offset 3 = "ll" in hello (1 prefix + 2 into "hello")
        XCTAssertFalse(ListEditingFSM.isAtHomePosition(storageIndex: 3, in: proj))
    }

    func test_isAtHomePosition_false_paragraph() {
        let proj = makeProjection("hello\n")
        XCTAssertFalse(ListEditingFSM.isAtHomePosition(storageIndex: 0, in: proj))
    }

    // MARK: - 9. isCurrentItemEmpty

    func test_isCurrentItemEmpty_true() {
        let doc = Document(blocks: [
            .list(items: [
                ListItem(indent: "", marker: "-", afterMarker: " ", inline: [], children: [])
            ])
        ])
        let proj = DocumentProjection(document: doc, bodyFont: bodyFont(), codeFont: codeFont())
        // Inline starts at prefix 1 (attachment)
        XCTAssertTrue(ListEditingFSM.isCurrentItemEmpty(storageIndex: 1, in: proj))
    }

    func test_isCurrentItemEmpty_false() {
        let proj = makeProjection("- hello\n")
        // Inline starts at 1
        XCTAssertFalse(ListEditingFSM.isCurrentItemEmpty(storageIndex: 1, in: proj))
    }

    // MARK: - 10. Indent then unindent round-trip

    func test_indent_then_unindent_roundTrips() {
        let original = "- alpha\n- beta\n"
        let proj = makeProjection(original)

        // Indent beta. inline at 6 + 1 + 1 = 8
        let afterIndent = try! EditingOps.indentListItem(at: 8, in: proj)
        // Find beta in the indented projection.
        let indentedEntries = EditingOps.flattenListPublic(
            afterIndent.newProjection.document.blocks[0].listItems!
        )
        // beta is now at depth 1; find its inline start.
        let betaEntry = indentedEntries.first { $0.depth == 1 }!
        let betaInlineStart = afterIndent.newProjection.blockSpans[0].location + betaEntry.startOffset + betaEntry.prefixLength

        // Unindent it back.
        let afterUnindent = try! EditingOps.unindentListItem(at: betaInlineStart, in: afterIndent.newProjection)
        let serialized = MarkdownSerializer.serialize(afterUnindent.newProjection.document)
        XCTAssertEqual(serialized, original, "Indent→unindent should round-trip")
    }
}

// MARK: - Block helper extension for tests

private extension Block {
    var listItems: [ListItem]? {
        if case .list(let items, _) = self { return items }
        return nil
    }
}
