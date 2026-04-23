//
//  Phase75cUDProxyTests.swift
//  FSNotesTests
//
//  Phase 7.5.c — UserDefaultsManagement → Theme proxy.
//
//  Verifies that each of the typography/layout UD properties turned
//  into a computed proxy over `Theme.shared`:
//    - Reads return the current Theme value (no UD round-trip).
//    - Writes mutate `Theme.shared` and post
//      `Theme.didChangeNotification`.
//
//  Also covers the one-time migration from legacy UD keys into Theme
//  on first launch (`UserDefaultsManagement.migrateEditorKeysIntoTheme75c`).
//
//  Pure-function tests: no NSWindow, no storyboard. Shared singletons
//  (`Theme.shared`, `UserDefaults.standard`) are snapshotted in
//  `setUpWithError` and restored in `tearDownWithError` so parallel
//  tests don't collide.
//

import XCTest
import Cocoa
@testable import FSNotes

final class Phase75cUDProxyTests: XCTestCase {

    // MARK: - Shared state capture

    private var tmpRoot: URL!
    private var savedTheme: BlockStyleTheme!
    private var savedCurrentThemeName: String?

    override func setUpWithError() throws {
        tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FSNotesPhase75cUDProxyTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tmpRoot, withIntermediateDirectories: true
        )

        savedTheme = BlockStyleTheme.shared
        savedCurrentThemeName = UserDefaultsManagement.currentThemeName
    }

    override func tearDownWithError() throws {
        BlockStyleTheme.shared = savedTheme
        UserDefaultsManagement.currentThemeName = savedCurrentThemeName

        if let tmpRoot = tmpRoot {
            try? FileManager.default.removeItem(at: tmpRoot)
        }
    }

    // MARK: - Read-proxy: UD getter pulls from Theme.shared

    func test_phase75c_readNoteFontName_readsFromTheme() {
        BlockStyleTheme.shared.noteFontName = "Helvetica"
        XCTAssertEqual(
            UserDefaultsManagement.fontName, "Helvetica",
            "fontName getter must read through Theme.shared.noteFontName"
        )
    }

    func test_phase75c_readCodeFontName_readsFromTheme() {
        BlockStyleTheme.shared.codeFontName = "Menlo"
        XCTAssertEqual(
            UserDefaultsManagement.codeFontName, "Menlo",
            "codeFontName getter must read through Theme.shared.codeFontName"
        )
    }

    func test_phase75c_readFontSize_readsFromTheme() {
        BlockStyleTheme.shared.noteFontSize = 19
        XCTAssertEqual(
            UserDefaultsManagement.fontSize, 19,
            "fontSize getter must read through Theme.shared.noteFontSize"
        )
    }

    func test_phase75c_readCodeFontSize_readsFromTheme() {
        BlockStyleTheme.shared.codeFontSize = 15
        XCTAssertEqual(
            UserDefaultsManagement.codeFontSize, 15,
            "codeFontSize getter must read through Theme.shared.codeFontSize"
        )
    }

    func test_phase75c_readLineHeightMultiple_readsFromTheme() {
        BlockStyleTheme.shared.lineHeightMultiple = 1.7
        XCTAssertEqual(
            UserDefaultsManagement.lineHeightMultiple, 1.7,
            accuracy: 0.0001,
            "lineHeightMultiple getter must read through Theme.shared.lineHeightMultiple"
        )
    }

    func test_phase75c_readItalic_readsFromTheme() {
        BlockStyleTheme.shared.italic = "_"
        XCTAssertEqual(
            UserDefaultsManagement.italic, "_",
            "italic getter must read through Theme.shared.italic"
        )
    }

    func test_phase75c_readBold_readsFromTheme() {
        BlockStyleTheme.shared.bold = "**"
        XCTAssertEqual(
            UserDefaultsManagement.bold, "**",
            "bold getter must read through Theme.shared.bold"
        )
    }

    func test_phase75c_readMarginSize_readsFromTheme() {
        BlockStyleTheme.shared.marginSize = 42
        XCTAssertEqual(
            UserDefaultsManagement.marginSize, 42,
            accuracy: 0.0001,
            "marginSize getter must read through Theme.shared.marginSize"
        )
    }

    func test_phase75c_readLineWidth_readsFromTheme() {
        BlockStyleTheme.shared.lineWidth = 720
        XCTAssertEqual(
            UserDefaultsManagement.lineWidth, 720,
            accuracy: 0.0001,
            "lineWidth getter must read through Theme.shared.lineWidth"
        )
    }

    func test_phase75c_readImagesWidth_readsFromTheme() {
        BlockStyleTheme.shared.imagesWidth = 333
        XCTAssertEqual(
            UserDefaultsManagement.imagesWidth, 333,
            accuracy: 0.0001,
            "imagesWidth getter must read through Theme.shared.imagesWidth"
        )
    }

    // MARK: - Write-proxy: UD setter mutates Theme.shared + posts notification

    func test_phase75c_writeNoteFontName_mutatesTheme() {
        BlockStyleTheme.shared.noteFontName = nil
        let expectation = self.expectation(
            forNotification: BlockStyleTheme.didChangeNotification,
            object: nil, handler: nil
        )
        UserDefaultsManagement.fontName = "Menlo"

        XCTAssertEqual(
            BlockStyleTheme.shared.noteFontName, "Menlo",
            "Setter must mutate Theme.shared.noteFontName"
        )
        wait(for: [expectation], timeout: 2.0)
    }

    func test_phase75c_writeCodeFontName_mutatesTheme() {
        BlockStyleTheme.shared.codeFontName = "Source Code Pro"
        let expectation = self.expectation(
            forNotification: BlockStyleTheme.didChangeNotification,
            object: nil, handler: nil
        )
        UserDefaultsManagement.codeFontName = "Courier"

        XCTAssertEqual(
            BlockStyleTheme.shared.codeFontName, "Courier",
            "Setter must mutate Theme.shared.codeFontName"
        )
        wait(for: [expectation], timeout: 2.0)
    }

    func test_phase75c_writeFontSize_mutatesTheme() {
        BlockStyleTheme.shared.noteFontSize = 14
        let expectation = self.expectation(
            forNotification: BlockStyleTheme.didChangeNotification,
            object: nil, handler: nil
        )
        UserDefaultsManagement.fontSize = 22

        XCTAssertEqual(
            BlockStyleTheme.shared.noteFontSize, 22,
            "Setter must mutate Theme.shared.noteFontSize"
        )
        wait(for: [expectation], timeout: 2.0)
    }

    func test_phase75c_writeCodeFontSize_mutatesTheme() {
        BlockStyleTheme.shared.codeFontSize = 14
        let expectation = self.expectation(
            forNotification: BlockStyleTheme.didChangeNotification,
            object: nil, handler: nil
        )
        UserDefaultsManagement.codeFontSize = 16

        XCTAssertEqual(
            BlockStyleTheme.shared.codeFontSize, 16,
            "Setter must mutate Theme.shared.codeFontSize"
        )
        wait(for: [expectation], timeout: 2.0)
    }

    func test_phase75c_writeLineHeightMultiple_mutatesTheme() {
        BlockStyleTheme.shared.lineHeightMultiple = 1.0
        let expectation = self.expectation(
            forNotification: BlockStyleTheme.didChangeNotification,
            object: nil, handler: nil
        )
        UserDefaultsManagement.lineHeightMultiple = 1.5

        XCTAssertEqual(
            BlockStyleTheme.shared.lineHeightMultiple, 1.5, accuracy: 0.0001,
            "Setter must mutate Theme.shared.lineHeightMultiple"
        )
        wait(for: [expectation], timeout: 2.0)
    }

    func test_phase75c_writeItalic_mutatesTheme() {
        BlockStyleTheme.shared.italic = "*"
        let expectation = self.expectation(
            forNotification: BlockStyleTheme.didChangeNotification,
            object: nil, handler: nil
        )
        UserDefaultsManagement.italic = "_"

        XCTAssertEqual(
            BlockStyleTheme.shared.italic, "_",
            "Setter must mutate Theme.shared.italic"
        )
        wait(for: [expectation], timeout: 2.0)
    }

    func test_phase75c_writeBold_mutatesTheme() {
        BlockStyleTheme.shared.bold = "__"
        let expectation = self.expectation(
            forNotification: BlockStyleTheme.didChangeNotification,
            object: nil, handler: nil
        )
        UserDefaultsManagement.bold = "**"

        XCTAssertEqual(
            BlockStyleTheme.shared.bold, "**",
            "Setter must mutate Theme.shared.bold"
        )
        wait(for: [expectation], timeout: 2.0)
    }

    func test_phase75c_writeMarginSize_mutatesTheme() {
        BlockStyleTheme.shared.marginSize = 20
        let expectation = self.expectation(
            forNotification: BlockStyleTheme.didChangeNotification,
            object: nil, handler: nil
        )
        UserDefaultsManagement.marginSize = 50

        XCTAssertEqual(
            BlockStyleTheme.shared.marginSize, 50, accuracy: 0.0001,
            "Setter must mutate Theme.shared.marginSize"
        )
        wait(for: [expectation], timeout: 2.0)
    }

    func test_phase75c_writeLineWidth_mutatesTheme() {
        BlockStyleTheme.shared.lineWidth = 1000
        let expectation = self.expectation(
            forNotification: BlockStyleTheme.didChangeNotification,
            object: nil, handler: nil
        )
        UserDefaultsManagement.lineWidth = 800

        XCTAssertEqual(
            BlockStyleTheme.shared.lineWidth, 800, accuracy: 0.0001,
            "Setter must mutate Theme.shared.lineWidth"
        )
        wait(for: [expectation], timeout: 2.0)
    }

    func test_phase75c_writeImagesWidth_mutatesTheme() {
        BlockStyleTheme.shared.imagesWidth = 450
        let expectation = self.expectation(
            forNotification: BlockStyleTheme.didChangeNotification,
            object: nil, handler: nil
        )
        UserDefaultsManagement.imagesWidth = 600

        XCTAssertEqual(
            BlockStyleTheme.shared.imagesWidth, 600, accuracy: 0.0001,
            "Setter must mutate Theme.shared.imagesWidth"
        )
        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Migration: legacy UD keys → Theme.shared

    /// Seed raw legacy UD keys, run the migration, verify Theme.shared
    /// picked up the values + legacy keys were removed + sentinel set.
    func test_phase75c_migration_copiesLegacyUDKeysIntoTheme() throws {
        let defaults = UserDefaults.standard

        // Clear any prior sentinel + seed legacy keys with non-default
        // values a user might have saved before 7.5.c landed.
        defaults.removeObject(forKey: UserDefaultsManagement.theme75cMigrationCompleteKey)
        defaults.set("Helvetica", forKey: "font")
        defaults.set(18, forKey: "fontsize")
        defaults.set("Menlo", forKey: "codeFont")
        defaults.set(16, forKey: "codeFontSize")
        defaults.set(Float(6), forKey: "lineSpacingEditor")
        defaults.set(Float(1.6), forKey: "lineHeightMultipleKey")
        defaults.set(Float(880), forKey: "lineWidth")
        defaults.set(Float(33), forKey: "marginSize")
        defaults.set(Float(520), forKey: "imagesWidthKey")
        defaults.set("_", forKey: "italicKeyed")
        defaults.set("**", forKey: "boldKeyed")

        // Reset Theme.shared to a known baseline before migration so we
        // can observe the legacy values being copied into it.
        BlockStyleTheme.shared = BlockStyleTheme.default

        UserDefaultsManagement.migrateEditorKeysIntoTheme75c(
            userThemesDirectory: tmpRoot
        )

        // 1. Theme.shared must now hold the legacy values.
        XCTAssertEqual(BlockStyleTheme.shared.noteFontName, "Helvetica")
        XCTAssertEqual(BlockStyleTheme.shared.noteFontSize, 18)
        XCTAssertEqual(BlockStyleTheme.shared.codeFontName, "Menlo")
        XCTAssertEqual(BlockStyleTheme.shared.codeFontSize, 16)
        XCTAssertEqual(BlockStyleTheme.shared.editorLineSpacing, 6)
        XCTAssertEqual(BlockStyleTheme.shared.lineHeightMultiple, 1.6, accuracy: 0.0001)
        XCTAssertEqual(BlockStyleTheme.shared.lineWidth, 880)
        XCTAssertEqual(BlockStyleTheme.shared.marginSize, 33)
        XCTAssertEqual(BlockStyleTheme.shared.imagesWidth, 520)
        XCTAssertEqual(BlockStyleTheme.shared.italic, "_")
        XCTAssertEqual(BlockStyleTheme.shared.bold, "**")

        // 2. Legacy keys must be removed from UserDefaults.
        XCTAssertNil(defaults.object(forKey: "font"))
        XCTAssertNil(defaults.object(forKey: "fontsize"))
        XCTAssertNil(defaults.object(forKey: "codeFont"))
        XCTAssertNil(defaults.object(forKey: "codeFontSize"))
        XCTAssertNil(defaults.object(forKey: "lineSpacingEditor"))
        XCTAssertNil(defaults.object(forKey: "lineHeightMultipleKey"))
        XCTAssertNil(defaults.object(forKey: "lineWidth"))
        XCTAssertNil(defaults.object(forKey: "marginSize"))
        XCTAssertNil(defaults.object(forKey: "imagesWidthKey"))
        XCTAssertNil(defaults.object(forKey: "italicKeyed"))
        XCTAssertNil(defaults.object(forKey: "boldKeyed"))

        // 3. Sentinel must be set so migration won't re-run.
        XCTAssertTrue(
            defaults.bool(forKey: UserDefaultsManagement.theme75cMigrationCompleteKey),
            "Migration sentinel must be true after the first run"
        )
    }

    /// Second invocation must be a no-op (idempotent): after the first
    /// run sets the sentinel, subsequent calls cannot mutate Theme or
    /// re-seed any keys.
    func test_phase75c_migration_idempotent() throws {
        let defaults = UserDefaults.standard

        defaults.removeObject(forKey: UserDefaultsManagement.theme75cMigrationCompleteKey)
        defaults.set("Helvetica", forKey: "font")
        BlockStyleTheme.shared = BlockStyleTheme.default

        UserDefaultsManagement.migrateEditorKeysIntoTheme75c(
            userThemesDirectory: tmpRoot
        )

        XCTAssertEqual(BlockStyleTheme.shared.noteFontName, "Helvetica")
        XCTAssertNil(defaults.object(forKey: "font"))

        // Re-seed a different value. The second migration call must
        // bail at the sentinel check and NOT copy this into Theme.
        defaults.set("TotallyDifferentFont", forKey: "font")
        let themeBeforeSecondRun = BlockStyleTheme.shared

        UserDefaultsManagement.migrateEditorKeysIntoTheme75c(
            userThemesDirectory: tmpRoot
        )

        XCTAssertEqual(
            BlockStyleTheme.shared, themeBeforeSecondRun,
            "Second migration run must not mutate Theme.shared"
        )
        XCTAssertEqual(
            defaults.string(forKey: "font"), "TotallyDifferentFont",
            "Second migration run must not delete the re-seeded key"
        )

        // Clean up the re-seeded key for the next test.
        defaults.removeObject(forKey: "font")
    }

    // MARK: - Flat-field Codable tolerance

    /// Pre-7.5.c theme JSON files on disk do NOT carry the three new
    /// flat fields. Decoding a legacy payload must fall back to the
    /// compiled-in defaults and not throw.
    func test_phase75c_tolerantDecoder_missingFlatFields() throws {
        // A JSON payload that lacks `lineHeightMultiple`, `italic`, `bold`.
        let legacyJSON = """
        {
            "noteFontName": null,
            "noteFontSize": 14,
            "codeFontName": "Source Code Pro",
            "codeFontSize": 14,
            "editorLineSpacing": 4,
            "lineWidth": 1000,
            "marginSize": 20,
            "imagesWidth": 450,
            "headingFontScales": [2.0, 1.7, 1.4, 1.2, 1.1, 1.05],
            "headingSpacingBefore": [1.2, 1.0, 0.9, 0.8, 0.7, 0.6],
            "headingSpacingAfter": [0.67, 0.5, 0.4, 0.35, 0.3, 0.25],
            "paragraphSpacing": 12,
            "codeBlockLineSpacing": 0,
            "codeBlockParagraphSpacing": 16,
            "codeBlockSpacingBefore": 0,
            "listIndentScale": 1.8,
            "listCellScale": 2.0,
            "listBulletSizeScale": 0.7,
            "listNumberDrawScale": 1.0,
            "listCheckboxDrawScale": 1.2,
            "listBulletStrokeInset": 0.5,
            "listBulletStrokeWidth": 1.0,
            "listBlockSpacing": 16,
            "blockquoteBarInitialOffset": 2,
            "blockquoteBarSpacing": 10,
            "blockquoteBarWidth": 4,
            "blockquoteGapAfterBars": 4,
            "blockquoteBlockSpacing": 16,
            "tablePlaceholderWidth": 400,
            "tablePlaceholderHeight": 100,
            "tableBlockSpacing": 16,
            "hrBlockSpacing": 16,
            "htmlBlockLineSpacing": 0,
            "htmlBlockParagraphSpacing": 16,
            "htmlBlockSpacingBefore": 0,
            "highlightColor": {"red": 1.0, "green": 0.9, "blue": 0.0, "alpha": 0.5},
            "blankLineMinHeight": 0.01,
            "blankLineMaxHeight": 0.01
        }
        """

        let decoded = try JSONDecoder().decode(
            BlockStyleTheme.self, from: Data(legacyJSON.utf8)
        )

        // Missing flat fields fall back to the compiled-in defaults
        // (matching the pre-7.5.c UD defaults).
        XCTAssertEqual(
            decoded.lineHeightMultiple, BlockStyleTheme.default.lineHeightMultiple,
            accuracy: 0.0001,
            "Missing lineHeightMultiple must fall back to default"
        )
        XCTAssertEqual(
            decoded.italic, BlockStyleTheme.default.italic,
            "Missing italic must fall back to default"
        )
        XCTAssertEqual(
            decoded.bold, BlockStyleTheme.default.bold,
            "Missing bold must fall back to default"
        )
    }
}
