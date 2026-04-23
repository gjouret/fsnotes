//
//  EditTextView+Clicked.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 13.12.2025.
//  Copyright © 2025 Oleksandr Hlushchenko. All rights reserved.
//

import Foundation
import AppKit

extension EditTextView {
    override func clicked(onLink link: Any, at charIndex: Int) {
        if handleEmailLink(link) { return }
        if handleAnchorLink(link) { return }
        if handleWikiLink(link) { return }

        if !isAttachmentAtPosition(charIndex) {
            if handleRegularLink(link, at: charIndex) { return }
        }
    }

    /// Extract the wikilink target name from a `wiki:<target>` URL.
    /// Returns `nil` if the URL isn't a wiki scheme or has no target.
    ///
    /// Pure function: no side effects. The inline renderer emits
    /// `URL(string: "wiki:" + percent-encoded-target)` for every
    /// `[[target]]` or `[[target|display]]` wikilink; this reverses
    /// that transformation so the click handler can resolve the
    /// target against the note store.
    public static func wikiTarget(from link: Any) -> String? {
        // Accept either URL or String forms — NSTextView hands us
        // URL for attributed-string .link values and String for
        // legacy source-mode detectors.
        let absolute: String
        if let url = link as? URL {
            guard url.scheme?.lowercased() == "wiki" else { return nil }
            absolute = url.absoluteString
        } else if let str = link as? String {
            let lower = str.lowercased()
            guard lower.hasPrefix("wiki:") else { return nil }
            absolute = str
        } else {
            return nil
        }
        // Strip the "wiki:" prefix (case-insensitive) and
        // percent-decode whatever follows.
        let prefixLen = "wiki:".count
        guard absolute.count > prefixLen else { return nil }
        let encoded = String(absolute.dropFirst(prefixLen))
        let decoded = encoded.removingPercentEncoding ?? encoded
        return decoded.isEmpty ? nil : decoded
    }

    /// If `link` is a `wiki:` URL, resolve the target via
    /// `Storage.shared().getBy(titleOrName:)` and open the matching
    /// note. Falls back to the search path when no note matches —
    /// consistent with the `fsnotes://find?id=...` behavior.
    /// Returns `true` when the link was handled as a wikilink.
    public func handleWikiLink(_ link: Any) -> Bool {
        guard let target = EditTextView.wikiTarget(from: link) else {
            return false
        }
        // Resolve via the shared note store. If found, reuse the
        // existing open-by-title plumbing (select row + sidebar,
        // focus editor, record navigation history). If not found,
        // fall through to the search flow so the user sees the
        // partial matches in the notes list.
        guard let vc = NSApp.windows.compactMap({ $0.contentViewController as? ViewController }).first ??
                      (NSApp.mainWindow?.contentViewController as? ViewController) else {
            return true  // handled = don't let super.clicked open "wiki:X" as a URL
        }
        if let note = Storage.shared().getBy(titleOrName: target) {
            vc.cleanSearchAndEditArea(shouldBecomeFirstResponder: false, completion: { () -> Void in
                vc.notesTableView.selectRowAndSidebarItem(note: note)
                NSApp.mainWindow?.makeFirstResponder(vc.editor)
                vc.notesTableView.saveNavigationHistory(note: note)
            })
            return true
        }
        // Fallback: populate the search field with the target.
        vc.search.stringValue = target
        vc.search.window?.makeFirstResponder(vc.search)
        return true
    }

    public func handleEmailLink(_ link: Any) -> Bool {
        guard let emailString = link as? String,
              emailString.isValidEmail(),
              let mailURL = URL(string: "mailto:\(emailString)") else {
            return false
        }
        
        NSWorkspace.shared.open(mailURL)
        return true
    }

    public func handleAnchorLink(_ link: Any) -> Bool {
        guard let linkString = link as? String,
              linkString.startsWith(string: "#") else {
            return false
        }
        
        let title = String(linkString.dropFirst()).replacingOccurrences(of: "-", with: " ")
        guard let textRange = textStorage?.string.range(of: "# " + title),
              let nsRange = textStorage?.string.nsRange(from: textRange) else {
            return false
        }
        
        setSelectedRange(nsRange)
        scrollRangeToVisible(nsRange)
        return true
    }

    public func isAttachmentAtPosition(_ charIndex: Int) -> Bool {
        let range = NSRange(location: charIndex, length: 1)
        let char = attributedSubstring(forProposedRange: range, actualRange: nil)
        return char?.attribute(.attachment, at: 0, effectiveRange: nil) != nil
    }

    public func handleRegularLink(_ link: Any, at charIndex: Int) -> Bool {
        guard let url = convertToURL(link) else {
            super.clicked(onLink: link, at: charIndex)
            return true
        }
        
        // Handle file:// URLs
        if url.scheme == "file" {
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            return true
        }
        
        // Handle non-fsnotes URLs with modifiers
        if url.scheme != "fsnotes" {
            if let handled = handleURLWithModifiers(url, at: charIndex) {
                return handled
            }
        }
        
        super.clicked(onLink: link, at: charIndex)
        return true
    }

    private func convertToURL(_ link: Any) -> URL? {
        if let url = link as? URL {
            return url
        }
        
        if let linkString = link as? String {
            return linkString.createURL(for: self.note)
        }
        
        return nil
    }

    private func handleURLWithModifiers(_ url: URL, at charIndex: Int) -> Bool? {
        guard let event = NSApp.currentEvent else {
            return nil
        }
        
        // Shift: Open without activation
        if event.modifierFlags.contains(.shift) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.open(url, configuration: configuration, completionHandler: nil)
            return true
        }
        
        // Command: Open normally
        if event.modifierFlags.contains(.command) {
            NSWorkspace.shared.open(url)
            return true
        }
        
        // No modifier: Check user preferences
        if !UserDefaultsManagement.clickableLinks {
            setSelectedRange(NSRange(location: charIndex, length: 0))
            return true
        }
        
        return nil
    }
}
