//
//  ThemeDiscoveryTests.swift
//  FSNotesTests
//
//  Phase 7.4 — Theme discovery + load-by-name.
//
//  Pure-function tests for `Theme.availableThemes(...)` and
//  `Theme.load(named:...)`. No NSWindow, no AppKit UI — just
//  filesystem + JSON + the Phase 7.1 decoder. Each test injects a
//  tmp `userThemesDirectory` so the real
//  `~/Library/Application Support/FSNotes++/Themes` is not touched.
//

import XCTest
@testable import FSNotes

final class ThemeDiscoveryTests: XCTestCase {

    // MARK: - Helpers

    private var tmpRoot: URL!

    override func setUpWithError() throws {
        tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FSNotesThemeDiscoveryTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tmpRoot, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tmpRoot = tmpRoot {
            try? FileManager.default.removeItem(at: tmpRoot)
        }
    }

    /// Write a stub theme JSON to the given directory and return the
    /// URL. The JSON is minimal — just enough to decode into a valid
    /// `BlockStyleTheme` so `Theme.load(named:)` can return it.
    @discardableResult
    private func writeStubTheme(
        named name: String,
        in dir: URL,
        noteFontSize: CGFloat = 17.5
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )

        // Start from the bundled default JSON so we get a complete
        // payload, then mutate the distinctive field before writing.
        let (theme, nested) = BlockStyleTheme.loadBundledDefault()
        var mutableTheme = theme
        mutableTheme.noteFontSize = noteFontSize
        let data = try BlockStyleTheme.toJSON(theme: mutableTheme, nested: nested)

        let url = dir.appendingPathComponent("\(name).json")
        try data.write(to: url)
        return url
    }

    // MARK: - Tests

    /// The enumeration always surfaces at least one entry — the
    /// bundled "Default" — even when the user directory is empty.
    func test_phase74_availableThemes_includesDefault() {
        let userDir = tmpRoot.appendingPathComponent("empty-user-themes")
        let descriptors = Theme.availableThemes(userThemesDirectory: userDir)

        XCTAssertFalse(
            descriptors.isEmpty,
            "Available themes must always include the bundled default"
        )
        XCTAssertTrue(
            descriptors.contains(where: {
                $0.name.caseInsensitiveCompare(Theme.defaultThemeName) == .orderedSame
                    && $0.isBuiltIn
            }),
            "`Default` must appear as a built-in descriptor (got \(descriptors.map { $0.name }))"
        )
    }

    /// Dropping a stub JSON into the user themes directory makes it
    /// appear in the enumeration (after the bundled entries).
    func test_phase74_availableThemes_includesUserThemes() throws {
        let userDir = tmpRoot.appendingPathComponent("populated-user-themes")
        try writeStubTheme(named: "MyTheme", in: userDir)

        let descriptors = Theme.availableThemes(userThemesDirectory: userDir)

        guard let entry = descriptors.first(where: { $0.name == "MyTheme" }) else {
            XCTFail("User theme 'MyTheme' not discovered (got \(descriptors.map { $0.name }))")
            return
        }
        XCTAssertFalse(entry.isBuiltIn, "User theme must be marked isBuiltIn == false")
        XCTAssertEqual(entry.url?.lastPathComponent, "MyTheme.json")
    }

    /// `Theme.load(named:)` returns the actual JSON-backed theme,
    /// verifiable via a distinctive field that differs from the
    /// compiled-in default.
    func test_phase74_loadNamed_returnsCorrectTheme() throws {
        let userDir = tmpRoot.appendingPathComponent("load-correct")
        try writeStubTheme(named: "BigFont", in: userDir, noteFontSize: 42)

        let theme = Theme.load(named: "BigFont", userThemesDirectory: userDir)
        XCTAssertEqual(
            theme.noteFontSize, 42,
            "Loading 'BigFont' must return the distinctive font size from disk"
        )
    }

    /// Unknown theme name falls back to the compiled-in / bundled
    /// default — never throws, never crashes.
    func test_phase74_loadNamed_fallsBackToDefault_onMissing() {
        let userDir = tmpRoot.appendingPathComponent("missing")
        let theme = Theme.load(
            named: "NopeNotARealTheme",
            userThemesDirectory: userDir
        )

        let expected = BlockStyleTheme.default
        XCTAssertEqual(
            theme.noteFontSize, expected.noteFontSize,
            "Unknown theme must fall back to the bundled default"
        )
        XCTAssertEqual(theme.codeFontName, expected.codeFontName)
    }

    /// A corrupt JSON file falls back to the bundled default via the
    /// existing Phase 7.1 error path. The file is still discovered
    /// (it has the right extension) but load fails safely.
    func test_phase74_loadNamed_fallsBackToDefault_onCorruptJSON() throws {
        let userDir = tmpRoot.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(
            at: userDir, withIntermediateDirectories: true
        )
        let url = userDir.appendingPathComponent("Busted.json")
        try Data("{ this is not valid JSON ".utf8).write(to: url)

        // Sanity: discovery sees it (it has the .json extension).
        let descriptors = Theme.availableThemes(userThemesDirectory: userDir)
        XCTAssertTrue(
            descriptors.contains(where: { $0.name == "Busted" }),
            "Corrupt file must still be discoverable by name"
        )

        // Load: corrupt → fall back to the bundled default.
        let theme = Theme.load(named: "Busted", userThemesDirectory: userDir)
        let expected = BlockStyleTheme.default
        XCTAssertEqual(
            theme.noteFontSize, expected.noteFontSize,
            "Corrupt JSON must fall back to the bundled default"
        )
    }
}
