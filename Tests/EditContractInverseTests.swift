//
//  EditContractInverseTests.swift
//  FSNotesTests
//
//  Phase 5f commit 1: validate `EditContract.InverseStrategy` —
//  the undo-primitive representation consumed by `UndoJournal`.
//
//  Every test here is pure-function: no AppKit, no NSWindow, no
//  layout. Round-trip property: for each tier, applying the inverse
//  to `afterDoc` must recover `beforeDoc` (byte-equal on
//  `Document.blocks` and `trailingNewline`). Tier A primitives
//  recover by re-running their sibling contract; Tier B/C recover
//  via `applyInverse(to:)` directly.
//

import XCTest
@testable import FSNotes

final class EditContractInverseTests: XCTestCase {

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

    // MARK: - buildInverse: tier selection

    func test_buildInverse_identicalDocuments_emitsEmptyTierB() {
        let doc = MarkdownParser.parse("First\n\nSecond")
        let strategy = EditContract.InverseStrategy.buildInverse(
            priorDoc: doc,
            newDoc: doc
        )
        if case let .blockSnapshot(range, blocks, ids) = strategy {
            // Identical docs → prefix consumes everything, changeWidth
            // is 0. The snapshot range is at-end and zero-width; its
            // exact location depends on `doc.blocks.count`.
            let expectedBound = doc.blocks.count
            XCTAssertEqual(range, expectedBound..<expectedBound,
                           "Identical docs: snapshot range is at-end zero-width")
            XCTAssertTrue(blocks.isEmpty)
            XCTAssertTrue(ids.isEmpty)
        } else {
            XCTFail("Expected Tier B zero-width snapshot, got \(strategy)")
        }
    }

    func test_buildInverse_singleBlockModified_emitsTierB() {
        let prior = MarkdownParser.parse("First\n\nSecond")
        var next = prior
        next.replaceBlock(at: 1, with: .paragraph(
            inline: [.text("Changed")]
        ))
        let strategy = EditContract.InverseStrategy.buildInverse(
            priorDoc: prior, newDoc: next
        )
        if case let .blockSnapshot(range, blocks, _) = strategy {
            XCTAssertEqual(range, 1..<2)
            XCTAssertEqual(blocks.count, 1)
            XCTAssertEqual(blocks[0], prior.blocks[1],
                           "Snapshot must hold the PRIOR block")
        } else {
            XCTFail("Expected Tier B single-block snapshot, got \(strategy)")
        }
    }

    func test_buildInverse_twoBlocksModified_emitsTierB() {
        let prior = MarkdownParser.parse("A\n\nB\n\nC")
        var next = prior
        next.replaceBlock(at: 1, with: .paragraph(inline: [.text("B2")]))
        next.replaceBlock(at: 2, with: .paragraph(inline: [.text("C2")]))
        let strategy = EditContract.InverseStrategy.buildInverse(
            priorDoc: prior, newDoc: next
        )
        if case let .blockSnapshot(range, blocks, _) = strategy {
            XCTAssertEqual(range, 1..<3)
            XCTAssertEqual(blocks.count, 2)
        } else {
            XCTFail("Expected Tier B multi-block snapshot, got \(strategy)")
        }
    }

    func test_buildInverse_wideChange_fallsBackToTierC() {
        let prior = MarkdownParser.parse("A\n\nB\n\nC\n\nD\n\nE\n\nF\n\nG")
        var next = prior
        // Replace 5 adjacent blocks — exceeds the Tier C threshold (4).
        next.replaceBlock(at: 1, with: .paragraph(inline: [.text("B2")]))
        next.replaceBlock(at: 2, with: .paragraph(inline: [.text("C2")]))
        next.replaceBlock(at: 3, with: .paragraph(inline: [.text("D2")]))
        next.replaceBlock(at: 4, with: .paragraph(inline: [.text("E2")]))
        next.replaceBlock(at: 5, with: .paragraph(inline: [.text("F2")]))
        let strategy = EditContract.InverseStrategy.buildInverse(
            priorDoc: prior, newDoc: next
        )
        if case let .fullDocument(savedDoc) = strategy {
            XCTAssertEqual(savedDoc, prior)
        } else {
            XCTFail("Expected Tier C full-document snapshot, got \(strategy)")
        }
    }

    func test_buildInverse_insertBlockInMiddle_tierBWithNewSlots() {
        let prior = MarkdownParser.parse("First\n\nLast")
        var next = prior
        let newBlock = Block.paragraph(inline: [.text("Middle")])
        next.insertBlock(newBlock, at: 1)
        let strategy = EditContract.InverseStrategy.buildInverse(
            priorDoc: prior, newDoc: next
        )
        if case let .blockSnapshot(range, blocks, _) = strategy {
            // Prefix = 1 ("First"), suffix = 1 ("Last").
            // Post-edit changed slot: [1..<1] ← prior had nothing, new
            // has one block. Inverse replaces newDoc.blocks[1..<2]
            // with [] (empty prior slice).
            XCTAssertEqual(range, 1..<2)
            XCTAssertEqual(blocks.count, 0,
                           "Insert-in-middle: prior slice is empty")
        } else {
            XCTFail("Expected Tier B snapshot, got \(strategy)")
        }
    }

    func test_buildInverse_deleteBlockInMiddle_tierBRestoresSlot() {
        let prior = MarkdownParser.parse("First\n\nMiddle\n\nLast")
        var next = prior
        next.removeBlock(at: 1)
        let strategy = EditContract.InverseStrategy.buildInverse(
            priorDoc: prior, newDoc: next
        )
        if case let .blockSnapshot(range, blocks, _) = strategy {
            XCTAssertEqual(range, 1..<1,
                           "Delete-in-middle: zero-width post-edit slot")
            XCTAssertEqual(blocks.count, 1)
            XCTAssertEqual(blocks[0], prior.blocks[1])
        } else {
            XCTFail("Expected Tier B snapshot, got \(strategy)")
        }
    }

    // MARK: - applyInverse: round-trip correctness

    func test_applyInverse_tierB_singleBlockModify_roundTrips() {
        let prior = MarkdownParser.parse("First\n\nSecond")
        var next = prior
        next.replaceBlock(at: 1, with: .paragraph(
            inline: [.text("Changed")]
        ))
        let strategy = EditContract.InverseStrategy.buildInverse(
            priorDoc: prior, newDoc: next
        )
        let recovered = strategy.applyInverse(to: next)
        XCTAssertEqual(recovered, prior,
                       "Tier B must round-trip prior == applyInverse(next)")
    }

    func test_applyInverse_tierB_blockInsertion_roundTrips() {
        let prior = MarkdownParser.parse("First\n\nLast")
        var next = prior
        next.insertBlock(.paragraph(inline: [.text("Middle")]), at: 1)
        let strategy = EditContract.InverseStrategy.buildInverse(
            priorDoc: prior, newDoc: next
        )
        let recovered = strategy.applyInverse(to: next)
        XCTAssertEqual(recovered, prior,
                       "Tier B must round-trip through block insert")
    }

    func test_applyInverse_tierB_blockDeletion_roundTrips() {
        let prior = MarkdownParser.parse("First\n\nMiddle\n\nLast")
        var next = prior
        next.removeBlock(at: 1)
        let strategy = EditContract.InverseStrategy.buildInverse(
            priorDoc: prior, newDoc: next
        )
        let recovered = strategy.applyInverse(to: next)
        XCTAssertEqual(recovered, prior,
                       "Tier B must round-trip through block delete")
    }

    func test_applyInverse_tierC_fullDocumentRoundTrips() {
        let prior = MarkdownParser.parse("A\n\nB\n\nC\n\nD\n\nE\n\nF\n\nG")
        var next = prior
        for i in 1...5 {
            next.replaceBlock(at: i, with: .paragraph(
                inline: [.text("x\(i)")]
            ))
        }
        let strategy = EditContract.InverseStrategy.buildInverse(
            priorDoc: prior, newDoc: next
        )
        let recovered = strategy.applyInverse(to: next)
        XCTAssertEqual(recovered, prior,
                       "Tier C full-document must round-trip exactly")
    }

    // MARK: - Corpus-driven round-trip via EditingOps

    /// For every primitive that produces a contract, `buildInverse`
    /// followed by `applyInverse` must recover the pre-edit document.
    /// This is the "inverse correctness" property from brief §7.1.
    func test_insert_singleChar_inverseRestoresPriorDoc() throws {
        let before = project("Hello world")
        let priorDoc = before.document
        let result = try EditingOps.insert("!", at: 5, in: before)
        let strategy = EditContract.InverseStrategy.buildInverse(
            priorDoc: priorDoc,
            newDoc: result.newProjection.document
        )
        let recovered = strategy.applyInverse(
            to: result.newProjection.document
        )
        XCTAssertEqual(recovered, priorDoc)
    }

    func test_delete_singleChar_inverseRestoresPriorDoc() throws {
        let before = project("Hello world")
        let priorDoc = before.document
        let result = try EditingOps.delete(
            range: NSRange(location: 5, length: 1),
            in: before
        )
        let strategy = EditContract.InverseStrategy.buildInverse(
            priorDoc: priorDoc,
            newDoc: result.newProjection.document
        )
        let recovered = strategy.applyInverse(
            to: result.newProjection.document
        )
        XCTAssertEqual(recovered, priorDoc)
    }

    func test_insertReturn_splitsParagraph_inverseRestoresPriorDoc() throws {
        let before = project("Hello world")
        let priorDoc = before.document
        let result = try EditingOps.insert("\n", at: 5, in: before)
        let strategy = EditContract.InverseStrategy.buildInverse(
            priorDoc: priorDoc,
            newDoc: result.newProjection.document
        )
        let recovered = strategy.applyInverse(
            to: result.newProjection.document
        )
        XCTAssertEqual(recovered, priorDoc,
                       "Return splits into 2 blocks; inverse rejoins")
    }

    func test_changeHeadingLevel_inverseRestoresPriorDoc() throws {
        let before = project("Para\n\n# Heading")
        let priorDoc = before.document
        let result = try EditingOps.changeHeadingLevel(2, at: 6, in: before)
        let strategy = EditContract.InverseStrategy.buildInverse(
            priorDoc: priorDoc,
            newDoc: result.newProjection.document
        )
        let recovered = strategy.applyInverse(
            to: result.newProjection.document
        )
        XCTAssertEqual(recovered, priorDoc)
    }

    // MARK: - annotateInverse helper

    func test_annotateInverse_setsStrategy_whenContractPresent() throws {
        let before = project("Hello world")
        var result = try EditingOps.insert("!", at: 5, in: before)
        XCTAssertNotNil(result.contract, "Insert must populate contract")
        XCTAssertNil(result.contract?.inverse,
                     "Insert does not annotate inverse by default")
        result.annotateInverse(priorDoc: before.document)
        XCTAssertNotNil(result.contract?.inverse,
                        "annotateInverse must populate strategy")
    }

    func test_annotateInverse_noContract_noop() {
        var result = EditResult(
            newProjection: project("x"),
            spliceRange: NSRange(location: 0, length: 0),
            spliceReplacement: NSAttributedString(string: "")
        )
        XCTAssertNil(result.contract)
        result.annotateInverse(priorDoc: project("x").document)
        XCTAssertNil(result.contract,
                     "annotateInverse on a nil contract must not materialize one")
    }
}
