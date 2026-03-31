//
//  FacadeTests.swift
//  FSNotesTests
//
//  Tests that extracted facades (EditorPreferences, NoteStore, etc.)
//  correctly delegate to the underlying implementation.
//

import XCTest
@testable import FSNotes

class FacadeTests: XCTestCase {

    // MARK: - EditorPreferences

    func test_editorPreferences_fontSize() {
        let prefs = EditorPreferences()
        XCTAssertGreaterThan(prefs.fontSize, 0)
    }

    func test_editorPreferences_noteFont() {
        let prefs = EditorPreferences()
        XCTAssertNotNil(prefs.noteFont)
    }

    func test_editorPreferences_boldMarker() {
        let prefs = EditorPreferences()
        XCTAssertTrue(prefs.boldMarker == "**" || prefs.boldMarker == "__")
    }

    func test_editorPreferences_italicMarker() {
        let prefs = EditorPreferences()
        XCTAssertTrue(prefs.italicMarker == "*" || prefs.italicMarker == "_")
    }

    // MARK: - AppEnvironment

    func test_appEnvironment_hasServices() {
        let env = AppEnvironment()
        XCTAssertNotNil(env.editorPreferences)
        XCTAssertNotNil(env.noteStore)
        XCTAssertNotNil(env.projectStore)
    }

    func test_appEnvironment_shared() {
        let env = AppEnvironment.shared
        XCTAssertNotNil(env)
    }

    func test_appEnvironment_testInit() {
        let mockPrefs = EditorPreferences()
        let env = AppEnvironment(editorPreferences: mockPrefs)
        XCTAssertNotNil(env.editorPreferences)
    }

    // MARK: - SecurityPreferences

    func test_securityPreferences_reads() {
        let prefs = SecurityPreferences()
        // Just verify they don't crash — actual values depend on UserDefaults
        _ = prefs.lockOnSleep
        _ = prefs.allowTouchID
    }

    // MARK: - GitPreferences

    func test_gitPreferences_reads() {
        let prefs = GitPreferences()
        XCTAssertGreaterThanOrEqual(prefs.snapshotsInterval, 0)
    }

    // MARK: - UIPreferences

    func test_uiPreferences_reads() {
        let prefs = UIPreferences()
        _ = prefs.horizontalOrientation
        _ = prefs.hidePreview
        _ = prefs.inlineTags
    }

    // MARK: - SyncPreferences

    func test_syncPreferences_reads() {
        let prefs = SyncPreferences()
        _ = prefs.fileFormat
    }

    // MARK: - NoteSerializer

    func test_noteSerializer_prepareForSave_plainText() {
        let attrStr = NSMutableAttributedString(string: "# Hello\n\nPlain text")
        _ = NoteSerializer.prepareForSave(attrStr)
        XCTAssertEqual(attrStr.string, "# Hello\n\nPlain text")
    }
}
