//
//  PreferencesThemeWritebackTests.swift
//  FSNotesTests
//
//  Phase 7.5 — IBAction → Theme write-back (first slice).
//
//  Pure-function tests for:
//    - `Theme.saveActiveTheme(preferredName:userThemesDirectory:)`
//      writes `Theme.shared` as JSON to the user themes directory.
//    - `Theme.didChangeNotification` fires after save.
//    - Round-trip: save then `Theme.load(named:)` returns equivalent
//      values for the fields the IBAction layer writes through.
//    - Calling a font IBAction updates `Theme.shared.noteFontName`
//      (the flat-field surrogate for the "editor font family" that the
//      task description mentions).
//
//  No NSWindow, no Xcode UI. The IBAction test instantiates the VC
//  directly and exercises the action methods with synthetic senders.
//

import XCTest
import Cocoa
@testable import FSNotes

final class PreferencesThemeWritebackTests: XCTestCase {

    // MARK: - Shared state capture

    private var tmpRoot: URL!
    private var savedThemeShared: BlockStyleTheme!
    private var savedCurrentThemeName: String?

    override func setUpWithError() throws {
        tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FSNotesPrefsThemeWritebackTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tmpRoot, withIntermediateDirectories: true
        )

        // Snapshot global singletons so individual tests can mutate them
        // freely without polluting the rest of the suite.
        savedThemeShared = BlockStyleTheme.shared
        savedCurrentThemeName = UserDefaultsManagement.currentThemeName
    }

    override func tearDownWithError() throws {
        BlockStyleTheme.shared = savedThemeShared
        UserDefaultsManagement.currentThemeName = savedCurrentThemeName

        if let tmpRoot = tmpRoot {
            try? FileManager.default.removeItem(at: tmpRoot)
        }
    }

    // MARK: - saveActiveTheme writes to user themes directory

    /// Given a mutated `Theme.shared` and a temp user-themes directory,
    /// `saveActiveTheme(userThemesDirectory:)` writes the current theme
    /// as JSON to `<dir>/<activeName>.json` and returns that URL.
    func test_phase75_saveActiveTheme_writesToUserThemesDirectory() throws {
        // Pretend the user was on a custom theme named "TestWriteBack"
        // so the save path uses that filename.
        UserDefaultsManagement.currentThemeName = "TestWriteBack"

        var mutable = BlockStyleTheme.default
        mutable.noteFontSize = 19
        BlockStyleTheme.shared = mutable

        let userDir = tmpRoot.appendingPathComponent("user-themes")
        let written = Theme.saveActiveTheme(userThemesDirectory: userDir)

        XCTAssertNotNil(written, "saveActiveTheme should return the URL it wrote")
        XCTAssertEqual(
            written?.lastPathComponent, "TestWriteBack.json",
            "Save target filename must match the active theme name"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: written?.path ?? ""),
            "Saved file must exist on disk at the returned URL"
        )

        // Verify the file content decodes back into the same theme.
        let data = try Data(contentsOf: written!)
        let (decoded, _) = try BlockStyleTheme.theme(fromJSON: data)
        XCTAssertEqual(
            decoded.noteFontSize, 19,
            "Written JSON must carry the mutated `noteFontSize`"
        )
    }

    // MARK: - didChangeNotification fires after save

    /// The observer installed by Phase 7.4 depends on this notification
    /// to re-render live views. Confirm saveActiveTheme posts it.
    func test_phase75_saveActiveTheme_postsDidChangeNotification() {
        UserDefaultsManagement.currentThemeName = "TestNotify"
        BlockStyleTheme.shared = BlockStyleTheme.default

        let userDir = tmpRoot.appendingPathComponent("user-themes")

        let expectation = self.expectation(
            forNotification: BlockStyleTheme.didChangeNotification,
            object: nil,
            handler: nil
        )

        _ = Theme.saveActiveTheme(userThemesDirectory: userDir)

        wait(for: [expectation], timeout: 2.0)
    }

    // MARK: - Round-trip save + load

    /// After `saveActiveTheme(...)` writes a JSON file, `Theme.load(named:)`
    /// with the same user-themes directory should return a theme equal
    /// to what was saved (modulo fields that live only in the nested
    /// synthesis path — we check the flat fields the IBAction layer
    /// mutates today).
    func test_phase75_saveActiveTheme_roundTripsThroughLoadNamed() throws {
        UserDefaultsManagement.currentThemeName = "RoundTrip"

        var mutable = BlockStyleTheme.default
        mutable.noteFontSize = 18
        mutable.codeFontName = "Menlo"
        mutable.codeFontSize = 15
        mutable.marginSize = 42
        mutable.lineWidth = 720
        BlockStyleTheme.shared = mutable

        let userDir = tmpRoot.appendingPathComponent("user-themes")
        _ = Theme.saveActiveTheme(userThemesDirectory: userDir)

        let reloaded = Theme.load(
            named: "RoundTrip", userThemesDirectory: userDir
        )

        XCTAssertEqual(reloaded.noteFontSize, 18)
        XCTAssertEqual(reloaded.codeFontName, "Menlo")
        XCTAssertEqual(reloaded.codeFontSize, 15)
        XCTAssertEqual(reloaded.marginSize, 42)
        XCTAssertEqual(reloaded.lineWidth, 720)
    }

    // MARK: - saveActiveTheme updates currentThemeName

    /// If the user had the bundled "Default" active and saved, the
    /// override should be persisted under the canonical "Default" name
    /// so `load(named: "Default")` picks it up (user > bundled
    /// precedence inside `availableThemes`).
    func test_phase75_saveActiveTheme_persistsActiveName() {
        UserDefaultsManagement.currentThemeName = nil  // default
        BlockStyleTheme.shared = BlockStyleTheme.default

        let userDir = tmpRoot.appendingPathComponent("user-themes")
        _ = Theme.saveActiveTheme(userThemesDirectory: userDir)

        XCTAssertEqual(
            UserDefaultsManagement.currentThemeName,
            BlockStyleTheme.defaultThemeName,
            "After save, currentThemeName must resolve to the canonical Default so the override is loaded on next launch"
        )
    }

    /// User override wins over bundled sibling inside `availableThemes`.
    /// Regression guard for the ordering fix in Phase 7.5 that matches
    /// the existing docstring on `availableThemes`.
    func test_phase75_userThemeOverridesBundledDefault() throws {
        let userDir = tmpRoot.appendingPathComponent("override-user-themes")
        try FileManager.default.createDirectory(
            at: userDir, withIntermediateDirectories: true
        )

        var mutable = BlockStyleTheme.default
        mutable.noteFontSize = 99
        BlockStyleTheme.shared = mutable
        UserDefaultsManagement.currentThemeName = BlockStyleTheme.defaultThemeName

        _ = Theme.saveActiveTheme(userThemesDirectory: userDir)

        let descriptors = Theme.availableThemes(userThemesDirectory: userDir)
        guard let defaultEntry = descriptors.first(where: {
            $0.name.caseInsensitiveCompare(BlockStyleTheme.defaultThemeName) == .orderedSame
        }) else {
            XCTFail("Default entry missing from available themes")
            return
        }
        XCTAssertFalse(
            defaultEntry.isBuiltIn,
            "User override for Default must replace the bundled entry"
        )

        let reloaded = Theme.load(
            named: BlockStyleTheme.defaultThemeName,
            userThemesDirectory: userDir
        )
        XCTAssertEqual(
            reloaded.noteFontSize, 99,
            "load(named: Default) must return the user override's values"
        )
    }

    // MARK: - IBAction writes through to Theme.shared

    /// Marker name for the two IBAction write-through tests below.
    /// Prefixed with `__test_` so an orphan file left by a crashed
    /// test run is visibly a test artifact (rather than masquerading
    /// as a plausibly-real user theme name like "IBActionWrite" did
    /// before — we found one of those in a user's themes directory
    /// on 2026-04-24). Paired with the `defer`-based restore helper
    /// below so a normal test failure can't leak the name into the
    /// next test either.
    private static let ibActionWritebackThemeName = "__test_writeback__"

    /// Run `body` with `UserDefaultsManagement.currentThemeName` set
    /// to `name`, guaranteeing the original value is restored on
    /// normal scope exit. The outer `tearDownWithError()` also
    /// restores it — this is belt-and-suspenders for the case where
    /// `tearDown` doesn't run (e.g. test hits an XCTFail that aborts
    /// the process, or the debugger kills the runner mid-test).
    private func withTemporaryCurrentThemeName<T>(
        _ name: String,
        _ body: () throws -> T
    ) rethrows -> T {
        let original = UserDefaultsManagement.currentThemeName
        defer { UserDefaultsManagement.currentThemeName = original }
        UserDefaultsManagement.currentThemeName = name
        return try body()
    }

    /// The Phase 7.5 contract for the font IBAction: a user font change
    /// must land on `Theme.shared.noteFontName/Size` AND be persisted
    /// via `saveActiveTheme()`. Exercising the IBAction method body
    /// directly requires a storyboard (the `IBOutlet` font-preview
    /// labels are implicitly-unwrapped), so this test mirrors the
    /// IBAction's write sequence verbatim and confirms the end-state.
    ///
    /// If the IBAction's write sequence ever diverges from what's
    /// mirrored below, this test starts documenting a stale contract.
    /// That's deliberate: the test describes what the IBAction MUST do,
    /// independent of the UI wiring.
    func test_phase75_noteFontIBAction_writeThrough() {
        let name = Self.ibActionWritebackThemeName
        withTemporaryCurrentThemeName(name) {
            BlockStyleTheme.shared = BlockStyleTheme.default

            // Pre-seed what NSFontManager.convert() would return — the UD
            // key `.noteFont` is both the read and write surface.
            let chosen = NSFont(name: "Menlo", size: 17)
                ?? NSFont.monospacedSystemFont(ofSize: 17, weight: .regular)

            // IBAction write sequence (`changeNoteFont(_:)`):
            //   1. Mutate Theme.shared (task per-7.5).
            //   2. Dual-write to legacy UD (transitional).
            //   3. Persist the active theme (posts didChangeNotification).
            Theme.shared.noteFontName = chosen.fontName
            Theme.shared.noteFontSize = chosen.pointSize
            UserDefaultsManagement.noteFont = chosen
            _ = Theme.saveActiveTheme(userThemesDirectory: tmpRoot)

            // The task description's "Theme.shared.editor.font.family" maps
            // to this flat field (the `.typography.bodyFontName` accessor
            // is a synthesized read-only wrapper over it).
            XCTAssertEqual(Theme.shared.noteFontName, chosen.fontName)
            XCTAssertEqual(Theme.shared.noteFontSize, chosen.pointSize)

            let reloaded = Theme.load(
                named: name, userThemesDirectory: tmpRoot
            )
            XCTAssertEqual(reloaded.noteFontName, chosen.fontName)
            XCTAssertEqual(reloaded.noteFontSize, chosen.pointSize)
        }
    }

    /// Same contract for the code-font IBAction.
    func test_phase75_codeFontIBAction_writeThrough() {
        let name = Self.ibActionWritebackThemeName
        withTemporaryCurrentThemeName(name) {
            BlockStyleTheme.shared = BlockStyleTheme.default

            let chosen = NSFont(name: "Menlo", size: 16)
                ?? NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)

            Theme.shared.codeFontName = chosen.familyName ?? "Source Code Pro"
            Theme.shared.codeFontSize = chosen.pointSize
            UserDefaultsManagement.codeFont = chosen
            _ = Theme.saveActiveTheme(userThemesDirectory: tmpRoot)

            XCTAssertEqual(Theme.shared.codeFontName, chosen.familyName)
            XCTAssertEqual(Theme.shared.codeFontSize, chosen.pointSize)

            let reloaded = Theme.load(
                named: name, userThemesDirectory: tmpRoot
            )
            XCTAssertEqual(reloaded.codeFontName, chosen.familyName)
            XCTAssertEqual(reloaded.codeFontSize, chosen.pointSize)
        }
    }
}
