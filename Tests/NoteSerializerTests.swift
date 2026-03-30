//
//  NoteSerializerTests.swift
//  FSNotesTests
//
//  Unit tests for NoteSerializer — the save pipeline that converts
//  WYSIWYG attributed strings back to clean markdown for disk.
//

import XCTest
@testable import FSNotes

class NoteSerializerTests: XCTestCase {

    // MARK: - Bullet Round-Trip

    func test_restoreBulletMarkers_dashToBullet() {
        let attrStr = NSMutableAttributedString(string: "\u{2022} Item")
        attrStr.addAttribute(.listBullet, value: "-", range: NSRange(location: 0, length: 1))

        NoteSerializer.restoreBulletMarkers(in: attrStr)

        XCTAssertEqual(attrStr.string, "- Item")
    }

    func test_restoreBulletMarkers_starToBullet() {
        let attrStr = NSMutableAttributedString(string: "\u{2022} Item")
        attrStr.addAttribute(.listBullet, value: "*", range: NSRange(location: 0, length: 1))

        NoteSerializer.restoreBulletMarkers(in: attrStr)

        XCTAssertEqual(attrStr.string, "* Item")
    }

    func test_restoreBulletMarkers_plusToBullet() {
        let attrStr = NSMutableAttributedString(string: "\u{2022} Item")
        attrStr.addAttribute(.listBullet, value: "+", range: NSRange(location: 0, length: 1))

        NoteSerializer.restoreBulletMarkers(in: attrStr)

        XCTAssertEqual(attrStr.string, "+ Item")
    }

    func test_restoreBulletMarkers_multipleItems() {
        // Build string with bullets and mark each with .listBullet
        let text = "\u{2022} First\n\u{2022} Second\n\u{2022} Third"
        let attrStr = NSMutableAttributedString(string: text)
        let nsText = text as NSString
        // Find and mark each bullet character
        var searchStart = 0
        while searchStart < nsText.length {
            let range = nsText.range(of: "\u{2022}", range: NSRange(location: searchStart, length: nsText.length - searchStart))
            if range.location == NSNotFound { break }
            attrStr.addAttribute(.listBullet, value: "-", range: range)
            searchStart = NSMaxRange(range)
        }

        NoteSerializer.restoreBulletMarkers(in: attrStr)

        XCTAssertEqual(attrStr.string, "- First\n- Second\n- Third")
    }

    func test_restoreBulletMarkers_noAttribute_noChange() {
        let attrStr = NSMutableAttributedString(string: "\u{2022} Item without attribute")

        NoteSerializer.restoreBulletMarkers(in: attrStr)

        // No .listBullet attribute → bullet char stays
        XCTAssertEqual(attrStr.string, "\u{2022} Item without attribute")
    }

    func test_restoreBulletMarkers_regularDash_noChange() {
        let attrStr = NSMutableAttributedString(string: "- Already a dash")

        NoteSerializer.restoreBulletMarkers(in: attrStr)

        XCTAssertEqual(attrStr.string, "- Already a dash")
    }

    func test_restoreBulletMarkers_emptyString() {
        let attrStr = NSMutableAttributedString(string: "")

        NoteSerializer.restoreBulletMarkers(in: attrStr)

        XCTAssertEqual(attrStr.string, "")
    }

    // MARK: - PrepareForSave Pipeline

    func test_prepareForSave_restoresBullets() {
        let attrStr = NSMutableAttributedString(string: "\u{2022} Item")
        attrStr.addAttribute(.listBullet, value: "-", range: NSRange(location: 0, length: 1))

        _ = NoteSerializer.prepareForSave(attrStr)

        XCTAssertEqual(attrStr.string, "- Item")
    }

    func test_prepareForSave_plainText_unchanged() {
        let attrStr = NSMutableAttributedString(string: "# Hello\n\nJust text")

        _ = NoteSerializer.prepareForSave(attrStr)

        XCTAssertEqual(attrStr.string, "# Hello\n\nJust text")
    }
}
