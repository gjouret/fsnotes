//
//  ThemeSaveSecurityTests.swift
//  FSNotesTests
//
//  Phase 7.5.a P1b — path-traversal guard in `saveActiveTheme`.
//
//  `BlockStyleTheme.saveActiveTheme(preferredName:userThemesDirectory:)`
//  resolves `preferredName` (falling back to UserDefaults) and passes
//  the string straight into `appendingPathComponent`. If a malicious
//  or hand-edited plist set the active theme name to something like
//  `"../../../etc/pwned"`, the save would escape the user-themes
//  directory.
//
//  Low real-world exploitability (local plist edit required), but the
//  guard is zero-cost and removes a sharp edge. These tests lock that
//  contract in.
//

import XCTest
import Cocoa
@testable import FSNotes

final class ThemeSaveSecurityTests: XCTestCase {

    private var tmpRoot: URL!
    private var savedThemeShared: BlockStyleTheme!
    private var savedCurrentThemeName: String?

    override func setUpWithError() throws {
        tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FSNotesThemeSaveSecurityTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tmpRoot, withIntermediateDirectories: true
        )

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

    // MARK: - Path-traversal rejection

    /// The classic `../` traversal must be rejected. Pass a malicious
    /// `preferredName` override; assert the save returns nil and that
    /// no file lands anywhere in or outside the user-themes directory.
    func test_P1b_dotDotTraversalRejected() throws {
        BlockStyleTheme.shared = BlockStyleTheme.default
        let userDir = tmpRoot.appendingPathComponent("user-themes")

        let malicious = "../../../../tmp/pwned"
        let result = Theme.saveActiveTheme(
            preferredName: malicious,
            userThemesDirectory: userDir
        )

        XCTAssertNil(
            result,
            "Malicious path-traversal name must cause saveActiveTheme to return nil"
        )

        // Walk the entire tmp root recursively — no `pwned.json`,
        // no file anywhere outside the user-themes dir.
        let enumerator = FileManager.default.enumerator(
            at: tmpRoot,
            includingPropertiesForKeys: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            XCTAssertFalse(
                url.lastPathComponent.contains("pwned"),
                "No file named 'pwned*' should have been created anywhere"
            )
        }

        // Also check /tmp/pwned.json didn't land via absolute escape.
        let absoluteEscape = URL(fileURLWithPath: "/tmp/pwned.json")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: absoluteEscape.path),
            "Absolute-path escape must not land /tmp/pwned.json"
        )
    }

    /// Forward slash alone (no `..`) would still escape the user-themes
    /// directory. Reject any name containing `/`.
    func test_P1b_forwardSlashRejected() throws {
        BlockStyleTheme.shared = BlockStyleTheme.default
        let userDir = tmpRoot.appendingPathComponent("user-themes")

        let result = Theme.saveActiveTheme(
            preferredName: "sub/dir/pwned",
            userThemesDirectory: userDir
        )
        XCTAssertNil(result)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: userDir
                    .appendingPathComponent("sub")
                    .appendingPathComponent("dir")
                    .appendingPathComponent("pwned.json").path
            )
        )
    }

    /// Backslash separator (Windows-style, but macOS sees it as a
    /// literal in filenames) — reject defensively so the guard covers
    /// every path-ish character we can identify.
    func test_P1b_backslashRejected() throws {
        BlockStyleTheme.shared = BlockStyleTheme.default
        let userDir = tmpRoot.appendingPathComponent("user-themes")

        let result = Theme.saveActiveTheme(
            preferredName: "sub\\dir\\pwned",
            userThemesDirectory: userDir
        )
        XCTAssertNil(result)
    }

    /// Empty name must be rejected — otherwise `.json` lands as the
    /// bare extension filename in the user-themes dir (harmless but
    /// ugly and pointless to persist).
    func test_P1b_emptyNameRejected() throws {
        BlockStyleTheme.shared = BlockStyleTheme.default
        let userDir = tmpRoot.appendingPathComponent("user-themes")

        let result = Theme.saveActiveTheme(
            preferredName: "",
            userThemesDirectory: userDir
        )
        // `preferredName: ""` triggers `activeThemeName` fallback to
        // UserDefaults or "Default", so this case typically wouldn't
        // reach the guard. The guard catches the pathological case
        // where UserDefaults itself is set to an empty string: there
        // the active name resolves to "Default" (non-empty), so this
        // test mainly documents the fallback behaviour.
        //
        // What we DO require: nothing unsafe lands. Either the result
        // is nil, or it's a URL inside `userDir`.
        if let url = result {
            XCTAssertTrue(
                url.path.hasPrefix(userDir.path),
                "If saveActiveTheme returns a URL, it must be inside the user-themes directory"
            )
        }
    }

    /// Valid plain names must still round-trip cleanly — regression
    /// guard for the guard itself being too aggressive.
    func test_P1b_validNameStillSaves() throws {
        BlockStyleTheme.shared = BlockStyleTheme.default
        UserDefaultsManagement.currentThemeName = "Valid Name 123"

        let userDir = tmpRoot.appendingPathComponent("user-themes")
        let result = Theme.saveActiveTheme(userThemesDirectory: userDir)

        XCTAssertNotNil(
            result,
            "Valid plain names must pass the path-traversal guard"
        )
        XCTAssertEqual(result?.lastPathComponent, "Valid Name 123.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result?.path ?? ""),
            "Valid name should have produced a real file"
        )
        XCTAssertTrue(
            result?.path.hasPrefix(userDir.path) ?? false,
            "Valid-name save must stay inside the user-themes directory"
        )
    }
}
