import XCTest
import AppKit
@testable import FSNotes

final class HeaderFoldingTests: XCTestCase {
    private func makeProcessor(for text: String) -> (processor: TextStorageProcessor, storage: NSTextStorage) {
        let storage = NSTextStorage(string: text)
        let processor = TextStorageProcessor()
        processor._testInstallSourceBlocks(parsing: storage.string as NSString)
        return (processor, storage)
    }

    func testFoldStopsAtNextSameLevelAtxHeader() {
        let text = """
        # Top
        alpha
        ## Child
        beta
        # Next
        omega
        """

        let (processor, storage) = makeProcessor(for: text)

        processor.toggleFold(headerBlockIndex: 0, textStorage: storage)

        let ns = text as NSString
        let foldedStart = ns.range(of: "alpha").location
        let nextHeader = ns.range(of: "# Next").location
        let childContent = ns.range(of: "beta")

        XCTAssertNotNil(storage.attribute(.foldedContent, at: foldedStart, effectiveRange: nil))
        XCTAssertNotNil(storage.attribute(.foldedContent, at: childContent.location, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.foldedContent, at: nextHeader, effectiveRange: nil))
    }

    func testFoldStopsAtNextSameLevelSetextHeader() {
        let text = """
        ## Top
        alpha
        Next
        ----
        omega
        """

        let (processor, storage) = makeProcessor(for: text)

        let snapshot = processor.sourceBlocksSnapshot
        XCTAssertEqual(snapshot.count, 4)
        XCTAssertEqual(snapshot[0].range.location, (text as NSString).range(of: "## Top").location)
        XCTAssertEqual(snapshot[1].type, .paragraph)
        XCTAssertEqual(snapshot[2].type, .headingSetext(level: 2))

        processor.toggleFold(headerBlockIndex: 0, textStorage: storage)

        let ns = text as NSString
        let foldedStart = ns.range(of: "alpha").location
        let setextHeader = ns.range(of: "Next").location
        var effectiveRange = NSRange(location: NSNotFound, length: 0)
        let value = storage.attribute(.foldedContent, at: setextHeader, effectiveRange: &effectiveRange)

        XCTAssertNotNil(storage.attribute(.foldedContent, at: foldedStart, effectiveRange: nil))
        XCTAssertNil(value, "Unexpected folded range at setext header: \(effectiveRange)")
    }

    func testFoldH1ContinuesThroughNestedSetextH2UntilNextH1() {
        let text = """
        # Top
        alpha
        Child
        -----
        beta
        # Next
        omega
        """

        let (processor, storage) = makeProcessor(for: text)

        processor.toggleFold(headerBlockIndex: 0, textStorage: storage)

        let ns = text as NSString
        let nestedSetextHeader = ns.range(of: "Child").location
        let nestedContent = ns.range(of: "beta").location
        let nextHeader = ns.range(of: "# Next").location

        XCTAssertNotNil(storage.attribute(.foldedContent, at: nestedSetextHeader, effectiveRange: nil))
        XCTAssertNotNil(storage.attribute(.foldedContent, at: nestedContent, effectiveRange: nil))
        XCTAssertNil(storage.attribute(.foldedContent, at: nextHeader, effectiveRange: nil))
    }
}
