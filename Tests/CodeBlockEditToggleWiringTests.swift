//
//  CodeBlockEditToggleWiringTests.swift
//  FSNotesTests
//
//  Regression test for a live bug observed 2026-04-24: fenced code
//  blocks (and mermaid diagrams) rendered correctly but the Phase 8
//  `</>` hover toggle button never appeared. Root cause: the overlay
//  that positions the button (`CodeBlockEditToggleOverlay`) is reached
//  through a lazy associated-object getter on `ViewController`
//  (`codeBlockEditToggleOverlay` in `FSNotes/ViewController+Events.swift`).
//  The getter's first read constructs the overlay AND runs
//  `installObservers()`, which wires `NSText.didChangeNotification`,
//  `NSView.boundsDidChangeNotification`, and
//  `EditTextView.editingCodeBlocksDidChangeNotification` observers.
//  Those observers are what drive auto-reposition of the `</>` buttons
//  on every scroll, edit, and toggle-state change.
//
//  Phase 8 Slice 3 (`b693a42`) shipped the overlay class + Slice 4
//  (`9ba0d44`) added cursor-leaves auto-collapse, but neither commit
//  landed the call site that triggers the first read. Grep over
//  `FSNotes/` returned zero production readers of the property
//  (comments only). The overlay was therefore never instantiated, its
//  observers never installed, and `</>` buttons never appeared.
//
//  Parallel to `TableHandleOverlayWiringTests` — same lazy-getter bug
//  class that bit the table hover handles in commit `08506d3`.
//

import XCTest

final class CodeBlockEditToggleWiringTests: XCTestCase {

    /// Scans the production Swift source tree under `FSNotes/` for
    /// accesses to `codeBlockEditToggleOverlay`. Asserts at least one
    /// production reader exists beyond the declaration line and any
    /// comments. The underlying contract: the property's lazy
    /// initialiser has side effects (`installObservers()`), so if
    /// nothing reads it, those side effects never run and the overlay
    /// never wires into the NSTextView's event chain.
    func test_codeBlockEditToggleOverlay_hasAtLeastOneProductionReader() throws {
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
                guard line.contains("codeBlockEditToggleOverlay") else { continue }
                // Skip the declaration itself: "var codeBlockEditToggleOverlay:"
                if line.contains("var codeBlockEditToggleOverlay") { continue }
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
            "CodeBlockEditToggleOverlay's lazy getter has NO production " +
            "readers. The overlay is never constructed → " +
            "`installObservers()` never fires → scroll / edit / " +
            "`editingCodeBlocksDidChange` observers never register → " +
            "the `</>` hover button never appears on any code block. " +
            "Add a `codeBlockEditToggleOverlay.reposition()` call after " +
            "`fill(note:)` completes in the editor's load path, alongside " +
            "the equivalent `tableHandleOverlay.reposition()` call (see " +
            "ARCHITECTURE.md \"Code-Block Edit Toggle\" + " +
            "`ViewController+Events.swift` comment above the getter)."
        )
        // Leave the locations available if the assertion fails so the
        // diff between expected and actual readers is easy to read.
        if readerLocations.isEmpty == false {
            print("codeBlockEditToggleOverlay production readers: \(readerLocations.joined(separator: ", "))")
        }
    }

    // MARK: - Helpers

    /// Walk up from this test file's path to find the repo root
    /// (identified by `FSNotes.xcworkspace`). Test-time reflection:
    /// `#filePath` is a compile-time literal set to the absolute path
    /// of this source file.
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
