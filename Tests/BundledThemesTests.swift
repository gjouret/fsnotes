//
//  BundledThemesTests.swift
//  FSNotesTests
//
//  Phase 7.4 — Bundled theme verification.
//
//  The app now ships three themes: "Default", "Dark", and "High Contrast".
//  These tests lock in that every bundled JSON file parses cleanly via
//  the Phase 7.1 loader and shows up by its user-visible name in the
//  Phase 7.4 discovery path. The goal is to catch:
//    - a typo / invalid JSON introduced in a bundled theme
//    - a missing file reference in the Xcode project (theme on disk but
//      not copied into the .app bundle)
//    - a schema drift that makes a theme silently fall back to the
//      compiled-in default
//
//  All tests are pure — no NSWindow, no AppKit UI, just bundle +
//  filesystem + JSON parsing.
//

import XCTest
@testable import FSNotes

final class BundledThemesTests: XCTestCase {

    // MARK: - Helpers

    /// Returns all bundled `*.json` theme files across the candidate
    /// bundles: the top-level `default-theme.json` + any `Themes/*.json`
    /// inside the app bundle. Duplicates (same lowercased basename) are
    /// collapsed — matching how `availableThemes()` does it.
    private func bundledThemeFiles() -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        let bundles: [Bundle] = [Bundle.main, Bundle(for: BundledThemesTests.self)]

        for bundle in bundles {
            // Top-level default-theme.json.
            if let url = bundle.url(
                forResource: "default-theme", withExtension: "json"
            ) {
                let key = url.deletingPathExtension().lastPathComponent.lowercased()
                if !seen.contains(key) {
                    seen.insert(key)
                    result.append(url)
                }
            }
            // Themes/ subdirectory (the folder-reference the app ships).
            guard let resourcePath = bundle.resourcePath else { continue }
            let themesDir = URL(fileURLWithPath: resourcePath)
                .appendingPathComponent("Themes")
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: themesDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for fileURL in contents
                where fileURL.pathExtension.lowercased() == "json" {
                let key = fileURL.deletingPathExtension()
                    .lastPathComponent.lowercased()
                if seen.contains(key) { continue }
                seen.insert(key)
                result.append(fileURL)
            }
        }
        return result
    }

    /// Returns `true` when `loaded` differs from the compiled-in default
    /// in at least one visible way — so we can assert that the theme was
    /// actually parsed from its JSON, not silently substituted with the
    /// default via the Phase-7.1 error fallback path. We compare a few
    /// distinctive fields rather than the whole struct so a bundled
    /// theme that happens to reuse a default value for some fields
    /// still registers as "not falling back."
    private func differsFromDefault(_ loaded: Theme) -> Bool {
        let def = Theme.default
        if loaded.highlightColor != def.highlightColor { return true }

        // Compare a few nested-color fields via their hex representation
        // so a theme with a distinctive code-block border, kbd chrome,
        // or heading border reads as "non-default." These are the
        // fields the Dark + High Contrast themes move most aggressively.
        let nested = loaded.colors
        let defNested = def.colors
        if nested.codeBlockBorder != defNested.codeBlockBorder { return true }
        if nested.kbdFill        != defNested.kbdFill         { return true }
        if nested.kbdForeground  != defNested.kbdForeground   { return true }
        if nested.hrLine         != defNested.hrLine          { return true }
        if nested.headingBorder  != defNested.headingBorder   { return true }
        if nested.blockquoteBar  != defNested.blockquoteBar   { return true }
        return false
    }

    // MARK: - Tests

    /// `Dark` must be discoverable by name and must parse into a theme
    /// whose visible color fields differ from the compiled-in default
    /// (proving we loaded the JSON rather than falling back).
    func test_phase74bundled_darkThemeLoads() {
        let descriptors = Theme.availableThemes()
        XCTAssertTrue(
            descriptors.contains(where: {
                $0.name.caseInsensitiveCompare("Dark") == .orderedSame
            }),
            "'Dark' must appear in availableThemes() (got \(descriptors.map { $0.name }))"
        )

        let theme = Theme.load(named: "Dark")
        XCTAssertTrue(
            differsFromDefault(theme),
            "'Dark' must resolve to a non-default theme — if this fails, the JSON likely fell back to the compiled-in default via the error path."
        )
    }

    /// `High Contrast` must be discoverable by name and must parse into
    /// a theme whose visible fields differ from the compiled-in default.
    func test_phase74bundled_highContrastThemeLoads() {
        let descriptors = Theme.availableThemes()
        XCTAssertTrue(
            descriptors.contains(where: {
                $0.name.caseInsensitiveCompare("High Contrast") == .orderedSame
            }),
            "'High Contrast' must appear in availableThemes() (got \(descriptors.map { $0.name }))"
        )

        let theme = Theme.load(named: "High Contrast")
        XCTAssertTrue(
            differsFromDefault(theme),
            "'High Contrast' must resolve to a non-default theme — if this fails, the JSON likely fell back to the compiled-in default via the error path."
        )
    }

    /// Walk every `*.json` we ship as a bundled theme and confirm each
    /// parses cleanly via `Theme.decodeWithNested(from:)`. Also confirm
    /// that `Theme.load(named:)` returns a theme matching that JSON's
    /// distinctive fields — i.e. the discovery path resolves the same
    /// file that's on disk.
    func test_phase74bundled_allBundledThemesParse() throws {
        let files = bundledThemeFiles()
        XCTAssertFalse(
            files.isEmpty,
            "Expected at least the three bundled themes (Default, Dark, High Contrast) — found none. Xcode registration likely missing."
        )

        // Every bundled JSON must decode via the strict path.
        for url in files {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                XCTFail("Failed to read bundled theme at \(url.path): \(error)")
                continue
            }
            do {
                let (theme, nested) = try Theme.decodeWithNested(from: data)
                // Smoke test: the flat + nested must both be non-empty
                // and validation must pass (otherwise the loader would
                // have thrown).
                XCTAssertGreaterThan(
                    theme.noteFontSize, 0,
                    "Bundled theme at \(url.lastPathComponent) has non-positive noteFontSize"
                )
                XCTAssertGreaterThan(
                    nested.typography.bodyFontSize, 0,
                    "Bundled theme at \(url.lastPathComponent) has non-positive nested bodyFontSize"
                )
            } catch {
                XCTFail("Bundled theme at \(url.path) failed strict decode: \(error)")
            }
        }

        // Each discovered name resolves via Theme.load(named:) without
        // silently falling back to the compiled-in default for the
        // non-"Default" themes.
        let descriptors = Theme.availableThemes()
        for descriptor in descriptors where descriptor.isBuiltIn {
            let theme = Theme.load(named: descriptor.name)

            // The canonical Default is *expected* to be field-equivalent
            // to the compiled-in default, so only assert divergence for
            // the non-default bundled entries.
            if descriptor.name.caseInsensitiveCompare(Theme.defaultThemeName)
                == .orderedSame {
                continue
            }
            XCTAssertTrue(
                differsFromDefault(theme),
                "Bundled theme '\(descriptor.name)' resolved to the compiled-in default — JSON likely malformed or not included in the .app bundle."
            )
        }
    }
}
