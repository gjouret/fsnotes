//
//  SplitViewPaneRestoreTests.swift
//  FSNotesTests
//
//  Bug #17 regression coverage. When the user shrinks the app window so
//  narrow that NSSplitView auto-collapses the folder pane and notes-list
//  pane (frame.width → 0), then widens the window again, both panes must
//  re-expand to their pre-resize widths.
//
//  The fix lives in `MainWindowController`:
//
//    - `windowWillStartLiveResize` snapshots both subview widths.
//    - `splitViewDidResizeSubviews` skips its UserDefaults write while
//      `window.inLiveResize == true` so cascade-shrink widths don't
//      pollute the persisted target.
//    - `windowDidResize` / `windowDidEndLiveResize` call
//      `restoreCollapsedPanesIfNeeded`, which uses the snapshot (or
//      UserDefaults as fallback) to set divider positions when the
//      window is wide enough to hold the panes again.
//
//  This file tests the pure helper `computeRestoredPaneWidths`, which
//  is the algorithm without any AppKit window/state coupling.
//

import XCTest
@testable import FSNotes

final class SplitViewPaneRestoreTests: XCTestCase {

    // MARK: - Both panes collapsed, window grew wide enough

    func test_bothCollapsed_windowWideEnough_restoresBoth() {
        let result = MainWindowController.computeRestoredPaneWidths(
            currentSidebar: 0,
            currentNotesList: 0,
            targetSidebar: 200,
            targetNotesList: 300,
            windowWidth: 1200,
            sidebarHidden: false
        )
        XCTAssertEqual(result.sidebar, 200)
        XCTAssertEqual(result.notesList, 300)
    }

    // MARK: - Both panes collapsed, window still too narrow

    func test_bothCollapsed_windowTooNarrow_restoresNeither() {
        // 200 + 300 + 300 (editor min) = 800 needed for both. 700 < 800.
        let result = MainWindowController.computeRestoredPaneWidths(
            currentSidebar: 0,
            currentNotesList: 0,
            targetSidebar: 200,
            targetNotesList: 300,
            windowWidth: 700,
            sidebarHidden: false
        )
        XCTAssertNil(result.sidebar)
        // Inner split alone needs 300 + 300 = 600, fits in 700.
        XCTAssertEqual(result.notesList, 300)
    }

    func test_bothCollapsed_windowFitsNotesListOnly() {
        // 600 fits notes list (300 + 300 editor min) but not sidebar
        // (200 + 300 + 300 = 800).
        let result = MainWindowController.computeRestoredPaneWidths(
            currentSidebar: 0,
            currentNotesList: 0,
            targetSidebar: 200,
            targetNotesList: 300,
            windowWidth: 600,
            sidebarHidden: false
        )
        XCTAssertNil(result.sidebar)
        XCTAssertEqual(result.notesList, 300)
    }

    // MARK: - Pane visible (not collapsed), no restore

    func test_paneAlreadyVisible_noRestore() {
        let result = MainWindowController.computeRestoredPaneWidths(
            currentSidebar: 200,
            currentNotesList: 300,
            targetSidebar: 200,
            targetNotesList: 300,
            windowWidth: 1200,
            sidebarHidden: false
        )
        XCTAssertNil(result.sidebar)
        XCTAssertNil(result.notesList)
    }

    // MARK: - User explicitly hid sidebar

    func test_sidebarExplicitlyHidden_doesNotRestoreSidebar() {
        let result = MainWindowController.computeRestoredPaneWidths(
            currentSidebar: 0,
            currentNotesList: 0,
            targetSidebar: 200,
            targetNotesList: 300,
            windowWidth: 1200,
            sidebarHidden: true
        )
        XCTAssertNil(result.sidebar, "sidebar must stay hidden when user toggled it off")
        XCTAssertEqual(result.notesList, 300)
    }

    // MARK: - Target width is zero / corrupt UserDefaults

    func test_zeroTarget_doesNotRestore() {
        let result = MainWindowController.computeRestoredPaneWidths(
            currentSidebar: 0,
            currentNotesList: 0,
            targetSidebar: 0,
            targetNotesList: 0,
            windowWidth: 1200,
            sidebarHidden: false
        )
        XCTAssertNil(result.sidebar)
        XCTAssertNil(result.notesList)
    }

    func test_targetBelowThreshold_doesNotRestore() {
        // Target of 30 is below the >50 floor — treat as "no real target".
        let result = MainWindowController.computeRestoredPaneWidths(
            currentSidebar: 0,
            currentNotesList: 0,
            targetSidebar: 30,
            targetNotesList: 30,
            windowWidth: 1200,
            sidebarHidden: false
        )
        XCTAssertNil(result.sidebar)
        XCTAssertNil(result.notesList)
    }

    // MARK: - Threshold edge cases

    func test_atExactThreshold_restores() {
        // Sidebar 200, notesList 300, editor min 300 → exactly 800.
        let result = MainWindowController.computeRestoredPaneWidths(
            currentSidebar: 0,
            currentNotesList: 0,
            targetSidebar: 200,
            targetNotesList: 300,
            windowWidth: 800,
            sidebarHidden: false
        )
        XCTAssertEqual(result.sidebar, 200)
        XCTAssertEqual(result.notesList, 300)
    }

    func test_oneBelowThreshold_skipsSidebar() {
        let result = MainWindowController.computeRestoredPaneWidths(
            currentSidebar: 0,
            currentNotesList: 0,
            targetSidebar: 200,
            targetNotesList: 300,
            windowWidth: 799,
            sidebarHidden: false
        )
        XCTAssertNil(result.sidebar)
        XCTAssertEqual(result.notesList, 300)
    }

    // MARK: - Mixed: sidebar visible, notes list collapsed

    func test_onlyNotesListCollapsed_restoresNotesListOnly() {
        let result = MainWindowController.computeRestoredPaneWidths(
            currentSidebar: 200,
            currentNotesList: 0,
            targetSidebar: 200,
            targetNotesList: 300,
            windowWidth: 1200,
            sidebarHidden: false
        )
        XCTAssertNil(result.sidebar)
        XCTAssertEqual(result.notesList, 300)
    }

    func test_onlySidebarCollapsed_restoresSidebarOnly() {
        let result = MainWindowController.computeRestoredPaneWidths(
            currentSidebar: 0,
            currentNotesList: 300,
            targetSidebar: 200,
            targetNotesList: 300,
            windowWidth: 1200,
            sidebarHidden: false
        )
        XCTAssertEqual(result.sidebar, 200)
        XCTAssertNil(result.notesList)
    }

    // MARK: - User has dragged a smaller pane than the saved value

    func test_currentNotesListWiderThanTarget_doesNotRestoreSidebar() {
        // The user has notes list at 400, sidebar collapsed. Target says
        // 300 + sidebar 200 + editor 300 = 800. But the *effective*
        // notes-list width (max of current=400 and target=300) is 400, so
        // the threshold becomes 200 + 400 + 300 = 900. Window of 850 must
        // not restore sidebar — would crowd out the editor.
        let result = MainWindowController.computeRestoredPaneWidths(
            currentSidebar: 0,
            currentNotesList: 400,
            targetSidebar: 200,
            targetNotesList: 300,
            windowWidth: 850,
            sidebarHidden: false
        )
        XCTAssertNil(result.sidebar)
        XCTAssertNil(result.notesList)
    }
}
