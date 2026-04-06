//
//  ListMarkerTests.swift
//  FSNotesTests
//
//  Regression tests for list marker depth variation:
//  - Leading-whitespace depth counting (tabs / 4-space groups)
//  - Visual bullet glyph variation by depth (•, ◦, ▪, ▫)
//
//  NOTE: The legacy phase4_hideSyntax function and its helpers
//  (alphaMarker, romanMarker, orderedMarkerText) have been removed.
//  The block model handles all list rendering via ListRenderer.
//

import XCTest
@testable import FSNotes

class ListMarkerTests: XCTestCase {

    // MARK: - Pure function: leadingListDepth

    func test_leadingListDepth_tabs() {
        XCTAssertEqual(TextStorageProcessor.leadingListDepth(""), 0)
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("- item"), 0)
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("\t- item"), 1)
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("\t\t- item"), 2)
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("\t\t\t- item"), 3)
    }

    func test_leadingListDepth_4spaces() {
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("    - item"), 1)
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("        - item"), 2)
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("            - item"), 3)
    }

    func test_leadingListDepth_partialSpacesIgnored() {
        // 3 spaces = not a depth level
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("   - item"), 0)
        // 5 spaces = 1 group + 1 leftover
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("     - item"), 1)
    }

    func test_leadingListDepth_mixedTabsAndSpaces() {
        // Tab + 4 spaces = 2
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("\t    - item"), 2)
        // 4 spaces + tab = 2
        XCTAssertEqual(TextStorageProcessor.leadingListDepth("    \t- item"), 2)
    }

    // MARK: - ListRenderer visual bullet glyphs

    func test_visualBullet_depthCycle() {
        XCTAssertEqual(ListRenderer.visualBullet(for: "-", depth: 0), "\u{2022}") // •
        XCTAssertEqual(ListRenderer.visualBullet(for: "-", depth: 1), "\u{25E6}") // ◦
        XCTAssertEqual(ListRenderer.visualBullet(for: "-", depth: 2), "\u{25AA}") // ▪
        XCTAssertEqual(ListRenderer.visualBullet(for: "-", depth: 3), "\u{25AB}") // ▫
        // Cycles back
        XCTAssertEqual(ListRenderer.visualBullet(for: "-", depth: 4), "\u{2022}") // •
    }

    func test_visualBullet_orderedPassthrough() {
        XCTAssertEqual(ListRenderer.visualBullet(for: "1.", depth: 0), "1.")
        XCTAssertEqual(ListRenderer.visualBullet(for: "2)", depth: 1), "2)")
    }

    func test_visualBullet_allUnorderedMarkers() {
        // All three unordered markers produce the same bullet glyphs
        for marker in ["-", "*", "+"] {
            XCTAssertEqual(ListRenderer.visualBullet(for: marker, depth: 0), "\u{2022}")
        }
    }
}
