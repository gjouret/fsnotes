//
//  BugFsnotes7qdTests.swift
//  FSNotesTests
//
//  Regression test for bd-fsnotes-7qd (P2):
//  "Code block / Mermaid edit toggle button not appearing on hover"
//

import XCTest
import AppKit
@testable import FSNotes

final class BugFsnotes7qdTests: XCTestCase {

    /// Verify the overlay detects code block fragments in WYSIWYG mode.
    func test_overlayFindsCodeBlockFragments() {
        let md = """
        # Test

        ```
        let x = 1
        ```

        Some text.
        """

        let h = EditorHarness(markdown: md, windowActivation: .keyWindow)
        defer { h.teardown() }

        guard let tlm = h.editor.textLayoutManager,
              let cs = tlm.textContentManager as? NSTextContentStorage
        else { XCTFail("no tlm/cs"); return }
        tlm.ensureLayout(for: tlm.documentRange)

        let overlay = CodeBlockEditToggleOverlay(editor: h.editor)
        let visible = overlay.visibleFragments()

        // Log what fragments are found
        bmLog("7qd-test: visibleFragments count=\(visible.count)")

        // Enumerate all fragment classes for diagnosis
        var classes: [String: Int] = [:]
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { f in
            let cls = String(describing: Swift.type(of: f))
            classes[cls, default: 0] += 1
            return true
        }
        bmLog("7qd-test: fragment classes=\(classes)")

        // Should find at least one code block fragment
        XCTAssertGreaterThan(
            visible.count, 0,
            "Should find at least one code block. Fragment classes: \(classes)"
        )
    }

    /// Verify mermaid blocks are also detected.
    func test_overlayFindsMermaidFragments() {
        let md = """
        ```mermaid
        graph TD
            A --> B
        ```
        """

        let h = EditorHarness(markdown: md, windowActivation: .keyWindow)
        defer { h.teardown() }

        guard let tlm = h.editor.textLayoutManager,
              let cs = tlm.textContentManager as? NSTextContentStorage
        else { XCTFail("no tlm/cs"); return }
        tlm.ensureLayout(for: tlm.documentRange)

        let overlay = CodeBlockEditToggleOverlay(editor: h.editor)
        let visible = overlay.visibleFragments()

        // Log fragment classes
        var classes: [String: Int] = [:]
        tlm.enumerateTextLayoutFragments(
            from: tlm.documentRange.location,
            options: [.ensuresLayout]
        ) { f in
            let cls = String(describing: Swift.type(of: f))
            classes[cls, default: 0] += 1
            return true
        }
        bmLog("7qd-mermaid: fragment classes=\(classes) visible=\(visible.count)")

        // Mermaid renders as MermaidLayoutFragment
        let hasMermaid = classes.keys.contains { $0.contains("Mermaid") }
        XCTAssertTrue(hasMermaid || visible.count > 0,
            "Mermaid block should be detected. Classes: \(classes)")
    }
}
