//
//  BitmapReadbackTests.swift
//  FSNotesTests
//
//  Phase 11 Slice C — demonstration tests for the four bitmap-based
//  `Then.*` readbacks added in `EditorAssertions+Bitmap.swift`.
//
//  Each test is an end-to-end exercise of one readback against a
//  scenario the production app actually paints — so a regression in
//  the underlying fragment draw path (folded indicator, kbd box, HR
//  line, dark-mode shading) flips the test red without anyone having
//  to file a bug first.
//
//  These are NOT pure-pipeline tests — they use `Given.keyWindowNote`
//  so the harness's window is key-active and TK2's viewport layout
//  controller fires the second-pass mount that fragment drawing
//  depends on.
//

import XCTest
@testable import FSNotes

final class BitmapReadbackTests: XCTestCase {

    // MARK: - 1. Folded-header indicator

    /// A folded H1 must paint its `[...]` indicator chip at the
    /// trailing edge of the heading. If the chip vanishes, the
    /// indicator-rect region of the rendered fragment contains
    /// only background pixels.
    func test_foldedHeader_indicatorRect_containsStrokePixels() {
        Given.keyWindowNote()
            .with(folded: .heading1)
            .Then.foldedHeader.indicatorRect.containsStrokePixels
    }

    // MARK: - 2. Kbd box

    /// A `<kbd>Cmd</kbd>` run in a paragraph must paint a rounded
    /// rectangle in the theme's `kbdStroke` color. If only the font
    /// changes (the user's reported symptom), zero stroke pixels
    /// land in the bitmap.
    func test_kbdSpan_boxRect_containsStrokePixels() {
        Given.keyWindowNote()
            .with(markdown: "Press <kbd>Cmd</kbd> to copy.\n")
            .Then.kbdSpan.boxRect.containsStrokePixels
    }

    // MARK: - 3. HR line

    /// A horizontal-rule block must paint a visible bar. An empty
    /// fragment (the bug class) produces a bitmap of pure background.
    func test_hr_fragmentAt0_contentDrawn() {
        Given.keyWindowNote()
            .with(horizontalRule: ())
            .Then.hr.fragment(at: 0).contentDrawn
    }

    // MARK: - 4. Dark-mode contrast

    /// In dark mode the `tableHeaderFill` background must keep enough
    /// contrast against the body-text foreground to satisfy WCAG AA
    /// (≥ 4.5:1). A dark-mode header that's too light or a foreground
    /// that resolves to system-default-dark-text against a dark fill
    /// fails the readback.
    func test_darkMode_contrast_tableHeader_meetsWCAG_AA() {
        Given.keyWindowNote()
            .with(markdown: "| H1 | H2 |\n|----|----|\n| a  | b  |\n")
            .Then.darkMode.contrast(of: .tableHeader).meetsWCAG_AA
    }
}
