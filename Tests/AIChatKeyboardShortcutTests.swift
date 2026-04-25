//
//  AIChatKeyboardShortcutTests.swift
//  FSNotesTests
//
//  Verifies that the View menu in `Main.storyboard` exposes a
//  "Hide/Show AI Chat" menu item bound to Cmd+Shift+A and routes
//  to ViewController.toggleAIChat(_:).
//
//  We can't dispatch a real key event from XCTest, so we assert
//  the menu-item shape directly: title, keyEquivalent, modifier
//  mask, action selector. This is the same surface AppKit reads
//  to wire the keyboard shortcut.
//

import XCTest
import AppKit
@testable import FSNotes

final class AIChatKeyboardShortcutTests: XCTestCase {

    /// Walks an NSMenu hierarchy depth-first and returns the first
    /// item whose title matches `title` (case-sensitive).
    private func findMenuItem(named title: String, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu = menu else { return nil }
        for item in menu.items {
            if item.title == title { return item }
            if let sub = item.submenu, let found = findMenuItem(named: title, in: sub) {
                return found
            }
        }
        return nil
    }

    /// Loads `Main.storyboard`, instantiates its initial controller
    /// (which forces `NSApp.mainMenu` to be populated as a side
    /// effect of the storyboard's menu owner) and returns the
    /// application's main menu.
    private func loadMainMenuFromStoryboard() -> NSMenu? {
        // Storyboard load — instantiating the initial controller is enough
        // to deserialize the menu hierarchy and assign NSApp.mainMenu.
        let storyboard = NSStoryboard(name: "Main", bundle: Bundle(for: ViewController.self))
        _ = storyboard.instantiateInitialController()
        return NSApp.mainMenu
    }

    func test_aiChatMenuItem_existsInViewMenu() {
        let menu = NSApp.mainMenu ?? loadMainMenuFromStoryboard()
        let item = findMenuItem(named: "Hide/Show AI Chat", in: menu)
        XCTAssertNotNil(item, "Expected 'Hide/Show AI Chat' menu item under the View menu")
    }

    func test_aiChatMenuItem_hasCmdShiftA() {
        let menu = NSApp.mainMenu ?? loadMainMenuFromStoryboard()
        guard let item = findMenuItem(named: "Hide/Show AI Chat", in: menu) else {
            XCTFail("Hide/Show AI Chat menu item not found")
            return
        }
        // AppKit / storyboard convention for Cmd+Shift+<letter>:
        //   - keyEquivalent is the UPPERCASE letter ("A"); the Shift modifier
        //     is implicit in the capitalization and is rendered by AppKit
        //     in the menu UI (e.g. "⇧⌘A"). It is NOT added to
        //     keyEquivalentModifierMask at runtime.
        //   - keyEquivalentModifierMask carries only the Command bit
        //     (matching the surrounding View-menu items "Hide/Show Note
        //     List" and "New Note in New Window").
        // Both the keyEquivalent capitalization AND the .command bit are
        // required for the shortcut to dispatch as Cmd+Shift+A.
        XCTAssertEqual(item.keyEquivalent, "A",
                       "keyEquivalent must be uppercase 'A' to imply the Shift modifier")
        XCTAssertTrue(
            item.keyEquivalentModifierMask.contains(.command),
            "Cmd modifier missing from AI Chat shortcut"
        )
    }

    func test_aiChatMenuItem_actionRoutesToToggleAIChat() {
        let menu = NSApp.mainMenu ?? loadMainMenuFromStoryboard()
        guard let item = findMenuItem(named: "Hide/Show AI Chat", in: menu) else {
            XCTFail("Hide/Show AI Chat menu item not found")
            return
        }
        XCTAssertEqual(item.action, #selector(ViewController.toggleAIChat(_:)))
    }
}
