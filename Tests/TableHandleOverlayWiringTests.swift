//
//  TableHandleOverlayWiringTests.swift
//  FSNotesTests
//
//  Regression test for a live bug observed 2026-04-24: tables rendered
//  correctly (grid, cell content, zebra striping) but were inert to
//  mouse input — no row/column hover handles appeared, and clicks
//  landed at nearby glyph offsets instead of inside cells. Root cause:
//  `ViewController.tableHandleOverlay` is a lazy associated-object
//  getter that constructs the overlay AND installs its observers on
//  first read. No production code ever read it, so `init(editor:)` +
//  `installObservers()` never fired, and the tracking areas / text-
//  change observers that drive handle display never existed.
//
//  Documented at `FSNotes/ViewController+Events.swift:383` as
//  "Production wiring: call `tableHandleOverlay.reposition()` after a
//  note is filled into the editor" — the call site was never landed
//  in the commit that introduced the overlay (Phase 2e T2-g.1,
//  `2590522`). This test prevents that regression from recurring.
//

import XCTest

final class TableHandleOverlayWiringTests: XCTestCase {

    /// Scans the production Swift source tree under `FSNotes/` for
    /// accesses to `tableHandleOverlay`. Asserts at least one
    /// production reader exists beyond the declaration line and any
    /// comments. The underlying contract: the property's lazy
    /// initialiser has side effects (`installObservers()`), so if
    /// nothing reads it, those side effects never run and the overlay
    /// never wires into the NSTextView's event chain.
    func test_tableHandleOverlay_hasAtLeastOneProductionReader() throws {
        let repoRoot = try repositoryRoot()
        let fsnotesDir = repoRoot.appendingPathComponent("FSNotes")

        var readerCount = 0
        var readerLocations: [String] = []

        let enumerator = FileManager.default.enumerator(
            at: fsnotesDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            for (lineIdx, rawLine) in lines.enumerated() {
                let line = String(rawLine)
                guard line.contains("tableHandleOverlay") else { continue }
                // Skip the declaration itself: "var tableHandleOverlay:"
                if line.contains("var tableHandleOverlay") { continue }
                // Skip single-line comment lines.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") {
                    continue
                }
                readerCount += 1
                let relative = url.path.replacingOccurrences(
                    of: repoRoot.path + "/", with: ""
                )
                readerLocations.append("\(relative):\(lineIdx + 1)")
            }
        }

        XCTAssertGreaterThan(
            readerCount, 0,
            "TableHandleOverlay's lazy getter has NO production readers. " +
            "The overlay is never constructed → `installObservers()` never " +
            "fires → tracking areas never register → no hover handles. " +
            "Add a `tableHandleOverlay.reposition()` call after `fill(note:)` " +
            "completes in the editor's load path (see ARCHITECTURE.md " +
            "Attachment Handling + `ViewController+Events.swift:383` comment)."
        )
        // Leave the locations available if the assertion fails so the
        // diff between expected and actual readers is easy to read.
        if readerLocations.isEmpty == false {
            print("tableHandleOverlay production readers: \(readerLocations.joined(separator: ", "))")
        }
    }

    // MARK: - Helpers

    /// Walk up from this test file's path to find the repo root
    /// (identified by `CLAUDE.md` + `FSNotes.xcworkspace` siblings).
    /// Test-time reflection: `#filePath` is a compile-time literal set
    /// to the absolute path of this source file.
    private func repositoryRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let marker = dir.appendingPathComponent("FSNotes.xcworkspace")
            if FileManager.default.fileExists(atPath: marker.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip(
            "Cannot locate repository root from \(#filePath) — test " +
            "requires running from a checkout of the FSNotes++ repo."
        )
    }
}
