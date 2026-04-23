//
//  ThemeSaveThrottleTests.swift
//  FSNotesTests
//
//  Phase 7.5.a P1a — rapid-fire `saveActiveThemeDebounced` calls must
//  collapse to a single disk write after the debounce window elapses.
//
//  Continuous `NSSlider` IBActions (`lineSpacing`, `marginSize`,
//  `lineWidth`, `imagesWidth`) tick at ~60Hz during a drag; each tick
//  calls `persistActiveTheme()` → `saveActiveThemeDebounced()`. The
//  contract under test: after 10 rapid-fire calls, exactly one JSON
//  file write lands at the destination path once the debounce
//  quiescence period elapses.
//
//  This is a pure-function test — no NSWindow, no NSSlider, no event
//  synthesis. The debounce helper lives in FSNotesCore and is exercised
//  directly here so the test doesn't need a live UI.
//

import XCTest
import Cocoa
@testable import FSNotes

final class ThemeSaveThrottleTests: XCTestCase {

    private var tmpRoot: URL!
    private var savedThemeShared: BlockStyleTheme!
    private var savedCurrentThemeName: String?

    override func setUpWithError() throws {
        tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FSNotesThemeSaveThrottleTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tmpRoot, withIntermediateDirectories: true
        )

        savedThemeShared = BlockStyleTheme.shared
        savedCurrentThemeName = UserDefaultsManagement.currentThemeName
        // Make sure no other test left a pending debounced save that
        // could fire into this one.
        Theme.cancelPendingDebouncedSave()
    }

    override func tearDownWithError() throws {
        Theme.cancelPendingDebouncedSave()
        BlockStyleTheme.shared = savedThemeShared
        UserDefaultsManagement.currentThemeName = savedCurrentThemeName

        if let tmpRoot = tmpRoot {
            try? FileManager.default.removeItem(at: tmpRoot)
        }
    }

    // MARK: - Rapid-fire collapses to one write

    /// Fire `saveActiveThemeDebounced` 10 times within 50ms. The target
    /// JSON file must:
    ///   - NOT exist immediately after the calls (writes are deferred).
    ///   - Exist exactly once after a pause longer than the debounce
    ///     interval (150ms default, we wait 400ms to be generous).
    ///   - Carry the FINAL caller's theme values (not an intermediate
    ///     tick's) — the debounce collapses to last-write-wins.
    func test_P1a_rapidFireSavesCollapseToOneWrite() throws {
        UserDefaultsManagement.currentThemeName = "ThrottleTest"

        let userDir = tmpRoot.appendingPathComponent("user-themes")
        let targetFile = userDir.appendingPathComponent("ThrottleTest.json")

        // 10 rapid-fire ticks — simulate one burst of slider events.
        // Each tick bumps `noteFontSize` so we can verify last-write-wins.
        for i in 0..<10 {
            var mutable = BlockStyleTheme.default
            mutable.noteFontSize = CGFloat(14 + i)  // 14...23
            BlockStyleTheme.shared = mutable

            Theme.saveActiveThemeDebounced(
                userThemesDirectory: userDir
            )
        }

        // Immediately after the burst: the debounce window is still
        // open, so no file should have been written yet.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: targetFile.path),
            "Debounced save must defer the disk write — file should not exist yet"
        )

        // Wait for the debounce interval + generous slack. Use a single
        // expectation + DispatchQueue; XCTestExpectation lets us block
        // without the main runloop-pumping hacks.
        let done = expectation(description: "debounced save completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            done.fulfill()
        }
        wait(for: [done], timeout: 2.0)

        // After the pause: exactly one write should have landed.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: targetFile.path),
            "One debounced save should have written the target file"
        )

        // Last-write-wins: the file on disk should carry the final
        // iteration's `noteFontSize` (23), not an intermediate value.
        let data = try Data(contentsOf: targetFile)
        let (decoded, _) = try BlockStyleTheme.theme(fromJSON: data)
        XCTAssertEqual(
            decoded.noteFontSize, 23,
            "Debounce must collapse to last-write-wins semantics"
        )
    }

    /// A single `saveActiveThemeDebounced` call (i.e. no rapid fire)
    /// must still land exactly one write after the debounce window.
    /// Guards against the "debounce eats the only call" regression.
    func test_P1a_singleCallStillProducesOneWrite() throws {
        UserDefaultsManagement.currentThemeName = "SingleCall"

        var mutable = BlockStyleTheme.default
        mutable.noteFontSize = 17
        BlockStyleTheme.shared = mutable

        let userDir = tmpRoot.appendingPathComponent("user-themes")
        let targetFile = userDir.appendingPathComponent("SingleCall.json")

        Theme.saveActiveThemeDebounced(userThemesDirectory: userDir)

        // Before debounce elapses: file absent.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: targetFile.path)
        )

        let done = expectation(description: "single save completes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            done.fulfill()
        }
        wait(for: [done], timeout: 2.0)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: targetFile.path),
            "Single debounced save should still land a write"
        )

        let data = try Data(contentsOf: targetFile)
        let (decoded, _) = try BlockStyleTheme.theme(fromJSON: data)
        XCTAssertEqual(decoded.noteFontSize, 17)
    }

    /// The per-tick `didChangeNotification` post must happen EAGERLY —
    /// live-preview observers on `EditTextView` depend on this to
    /// re-render the in-memory theme change at slider-tick cadence.
    /// Only the disk write is debounced.
    func test_P1a_notificationFiresEagerlyEveryCall() {
        UserDefaultsManagement.currentThemeName = "NotifyEager"
        BlockStyleTheme.shared = BlockStyleTheme.default

        let userDir = tmpRoot.appendingPathComponent("user-themes")

        let expectation = self.expectation(
            forNotification: BlockStyleTheme.didChangeNotification,
            object: nil,
            handler: nil
        )
        expectation.expectedFulfillmentCount = 5
        expectation.assertForOverFulfill = false

        // 5 rapid-fire calls — we expect 5 synchronous notifications,
        // even though only 1 disk write will ultimately happen.
        for _ in 0..<5 {
            Theme.saveActiveThemeDebounced(userThemesDirectory: userDir)
        }

        wait(for: [expectation], timeout: 1.0)
    }
}
