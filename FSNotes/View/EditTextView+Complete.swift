//
//  EditTextView+Complete.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 06.12.2025.
//  Copyright © 2025 Oleksandr Hlushchenko. All rights reserved.
//

import Foundation
import AppKit

// MARK: - Completion Context
enum CompletionContext: Equatable {
    case wikiLink(startPos: Int)
    case tag(startPos: Int)
    case codeBlock(startPos: Int)
    case none
    
    var startPosition: Int? {
        switch self {
        case .wikiLink(let pos), .tag(let pos), .codeBlock(let pos):
            return pos
        case .none:
            return nil
        }
    }
}

extension EditTextView {    
    // MARK: - Context Detection
    func detectCompletionContext() -> CompletionContext {
        let location = selectedRange().location
        let text = string as NSString
        
        if let codeBlockContext = detectCodeBlockContext(at: location, in: text) {
            return codeBlockContext
        }
        
        
        // Disable completion in code blocks
        guard let ranges = textStorageProcessor?.codeBlockRanges,
              !ranges.contains(where: { $0.contains(location) }) else { return .none }
                
        if let tagContext = detectTagContext(at: location, in: text) {
            return tagContext
        }
        
        if let wikiContext = detectWikiContext(at: location, in: text) {
            return wikiContext
        }
        
        return .none
    }
    
    private func detectCodeBlockContext(at location: Int, in text: NSString) -> CompletionContext? {
        guard location >= 3 else { return nil }

        let checkRange = NSRange(location: location - 3, length: 3)
        let lastChars = text.substring(with: checkRange)

        guard lastChars == "```" else {
            // Only offer language completions if we're on the opening fence line
            // (not inside a code block at the closing fence)
            return detectCodeBlockLanguageInput(at: location, in: text)
        }

        // Verify this ``` is at the start of a line (only whitespace before it)
        let lineStart = findLineStart(at: location - 3, in: text)
        if lineStart < location - 3 {
            let beforeRange = NSRange(location: lineStart, length: location - 3 - lineStart)
            let beforeText = text.substring(with: beforeRange)
            for char in beforeText {
                if char != " " && char != "\t" { return nil }
            }
        }

        // Don't show language menu for a CLOSING fence.
        // Count opening fences (``` at line start) before this position.
        // Odd count means we're closing an open block → no completion.
        let textBefore = text.substring(to: location - 3)
        var fenceCount = 0
        for line in textBefore.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if trimmed.hasPrefix("```") { fenceCount += 1 }
        }
        if fenceCount % 2 == 1 {
            return nil  // Odd number = this ``` closes an open fence
        }

        return .codeBlock(startPos: location)
    }
    
    private func detectCodeBlockLanguageInput(at location: Int, in text: NSString) -> CompletionContext? {
        var searchPos = location - 1
        
        while searchPos >= 0 && location - searchPos < 30 {
            if searchPos + 3 <= text.length {
                let checkRange = NSRange(location: searchPos, length: 3)
                let chars = text.substring(with: checkRange)
                
                if chars == "```" {
                    let lineStart = findLineStart(at: searchPos, in: text)
                    
                    if lineStart < searchPos {
                        let beforeRange = NSRange(location: lineStart, length: searchPos - lineStart)
                        let beforeText = text.substring(with: beforeRange)
                        
                        var isValidStart = true
                        for char in beforeText {
                            if char != " " && char != "\t" {
                                isValidStart = false
                                break
                            }
                        }
                        
                        if !isValidStart {
                            return nil
                        }
                    }
                    
                    let betweenRange = NSRange(location: searchPos + 3, length: location - searchPos - 3)
                    let betweenText = text.substring(with: betweenRange)
                    
                    if !betweenText.contains("\n") {
                        return .codeBlock(startPos: searchPos + 3)
                    }
                    
                    return nil
                }
            }
            searchPos -= 1
        }
        
        return nil
    }
    
    private func findLineStart(at position: Int, in text: NSString) -> Int {
        var pos = position - 1
        
        while pos >= 0 {
            let char = text.substring(with: NSRange(location: pos, length: 1))
            if char == "\n" {
                return pos + 1
            }
            pos -= 1
        }
        
        return 0
    }
    
    private func detectTagContext(at location: Int, in text: NSString) -> CompletionContext? {
        guard UserDefaultsManagement.inlineTags && location >= 1 else { return nil }

        var searchPos = location - 1

        while searchPos >= 0 && location - searchPos < 50 {
            let char = text.substring(with: NSRange(location: searchPos, length: 1))

            if char == "#" {
                // Skip if this is a header (multiple consecutive #'s at line start)
                if searchPos + 1 < text.length {
                    let nextChar = text.substring(with: NSRange(location: searchPos + 1, length: 1))
                    if nextChar == "#" || nextChar == " " {
                        // Could be a header (## or # followed by space)
                        let lineStart = findLineStart(at: searchPos, in: text)
                        if lineStart == searchPos {
                            break  // Line starts with # — treat as header, not tag
                        }
                    }
                }
                if isValidTagStart(at: searchPos, in: text) {
                    return .tag(startPos: searchPos)
                }
                break
            } else if isWhitespace(char) {
                break
            }

            searchPos -= 1
        }

        return nil
    }
    
    private func detectWikiContext(at location: Int, in text: NSString) -> CompletionContext? {
        var searchPos = location
        
        while searchPos >= 2 && location - searchPos < 100 {
            let checkRange = NSRange(location: searchPos - 2, length: 2)
            let chars = text.substring(with: checkRange)
            
            if chars == "[[" {
                let betweenRange = NSRange(location: searchPos, length: location - searchPos)
                let betweenText = text.substring(with: betweenRange)
                
                if !betweenText.contains("]]") {
                    return .wikiLink(startPos: searchPos)
                }
            }
            searchPos -= 1
        }
        
        return nil
    }
    
    // MARK: - Helpers
    private func isValidTagStart(at position: Int, in text: NSString) -> Bool {
        guard position >= 0 else { return false }
        
        if position == 0 {
            return true
        }
        
        let charBefore = text.substring(with: NSRange(location: position - 1, length: 1))
        return isWhitespace(charBefore)
    }
    
    private func isWhitespace(_ char: String) -> Bool {
        return char == " " || char == "\n" || char == "\t"
    }
    
    private func checkForClosingBrackets(at position: Int, in text: NSString) -> Bool {
        guard position + 2 <= text.length else { return false }
        
        let nextRange = NSRange(location: position, length: 2)
        let nextChars = text.substring(with: nextRange)
        return nextChars == "]]"
    }
    
    // MARK: - Completion Handlers
    func handleCompletions(index: UnsafeMutablePointer<Int>) -> [String]? {
        let context = detectCompletionContext()
        let currentPos = selectedRange().location
        let text = string as NSString
        
        index.pointee = 0
        
        switch context {
        case .codeBlock(let startPos):
            return getCodeBlockCompletions(startPos: startPos, currentPos: currentPos, text: text)
            
        case .tag(let startPos):
            return getTagCompletions(startPos: startPos, currentPos: currentPos, text: text)
            
        case .wikiLink(let startPos):
            return getWikiCompletions(startPos: startPos, currentPos: currentPos, text: text)
            
        case .none:
            return nil
        }
    }
    
    private func getCodeBlockCompletions(startPos: Int, currentPos: Int, text: NSString) -> [String]? {
        let searchLength = currentPos - startPos
        
        let codeLanguages = NotesTextProcessor.getHighlighter().getLanguages()
            .sorted()
        
        if searchLength == 0 {
            return codeLanguages
        }
        
        let searchRange = NSRange(location: startPos, length: searchLength)
        let searchText = text.substring(with: searchRange)
        
        let filtered = codeLanguages
            .filter { $0.localizedCaseInsensitiveContains(searchText) }
            .sorted { a, b in
                let aStarts = a.range(of: searchText, options: [.caseInsensitive, .anchored]) != nil
                let bStarts = b.range(of: searchText, options: [.caseInsensitive, .anchored]) != nil

                if aStarts != bStarts {
                    return aStarts && !bStarts
                }

                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
        
        return filtered.isEmpty ? nil : filtered
    }
    
    private func getTagCompletions(startPos: Int, currentPos: Int, text: NSString) -> [String]? {
        let searchLength = currentPos - startPos - 1
        
        if searchLength == 0 {
            if let tags = viewDelegate?.sidebarOutlineView.getAllTags() {
                return tags.sorted()
            }
        }
        
        let searchRange = NSRange(location: startPos + 1, length: searchLength)
        let searchText = text.substring(with: searchRange)
        
        if let tags = viewDelegate?.sidebarOutlineView.getAllTags() {
            let filtered = tags
                .filter { $0.startsWith(string: searchText) }
                .sorted()
            
            return filtered.isEmpty ? nil : filtered
        }
        
        return nil
    }
    
    private func getWikiCompletions(startPos: Int, currentPos: Int, text: NSString) -> [String]? {
        let searchLength = currentPos - startPos
        
        if searchLength == 0 {
            let titles = storage.noteList
                .map { String($0.title) }
                .filter { !$0.isEmpty }
                .sorted()
            
            return titles
        }
        
        let searchRange = NSRange(location: startPos, length: searchLength)
        let searchText = text.substring(with: searchRange)
        
        if let notes = storage.getBy(contains: searchText) {
            let titles = notes
                .map { String($0.title) }
                .filter { $0.localizedCaseInsensitiveContains(searchText) && !$0.isEmpty && $0 != searchText }
                .sorted()
            
            return titles
        }
        
        return nil
    }
    
    func handleInsertCompletion(word: String, movement: Int, isFinal flag: Bool) {
        guard flag && (movement == NSReturnTextMovement || movement == NSTabTextMovement) else {
            return
        }
        
        let context = detectCompletionContext()
        
        switch context {
        case .codeBlock(let startPos):
            insertCodeBlockCompletion(word, startPos: startPos)
            
        case .tag(let startPos):
            insertTagCompletion(word, startPos: startPos)
            
        case .wikiLink(let startPos):
            insertWikiCompletion(word, startPos: startPos)
            
        case .none:
            break
        }
    }
    
    private func insertCodeBlockCompletion(_ word: String, startPos: Int) {
        let currentPos = selectedRange().location
        let text = self.string as NSString
        let replaceRange = NSRange(location: startPos, length: currentPos - startPos)

        // Check if a closing ``` already exists on a subsequent line (within a few lines).
        // The insertCodeBlock template inserts "```\n\n```\n" — the closing fence is 2 lines ahead.
        var hasClosingFence = false
        var searchPos = currentPos
        var linesChecked = 0
        while searchPos < text.length && linesChecked < 4 {
            let lineRange = text.paragraphRange(for: NSRange(location: searchPos, length: 0))
            let line = text.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "```" {
                hasClosingFence = true
                break
            }
            if !line.isEmpty && line != "```" && linesChecked > 0 {
                break  // Non-empty, non-fence content — stop looking
            }
            searchPos = NSMaxRange(lineRange)
            if searchPos <= lineRange.location { break }
            linesChecked += 1
        }

        var completion = hasClosingFence
            ? "\(word)\n"
            : "\(word)\n\n```"

        // Inside code block without ```
        if let ranges = textStorageProcessor?.codeBlockRanges {
            for r in ranges where r.contains(startPos) {
                completion = word
                break
            }
        }

        suppressCompletion = true

        if shouldChangeText(in: replaceRange, replacementString: completion) {
            replaceCharacters(in: replaceRange, with: completion)
            didChangeText()
            setSelectedRange(NSRange(location: startPos + word.count + 1, length: 0))
        }
    }
    
    private func insertTagCompletion(_ word: String, startPos: Int) {
        let currentPos = selectedRange().location
        let replaceRange = NSRange(location: startPos + 1, length: currentPos - startPos - 1)
        let finalPos = startPos + 1 + word.count + 1   // past word + trailing space
        let completion = word + " "

        // Bug #33 (tag variant): route through block-model when active
        // so the projection stays in sync with storage. The raw
        // replaceCharacters + didChangeText path below bypasses the
        // block-model pipeline and leaves the rendered attributed
        // string out of sync.
        if let projection = documentProjection {
            do {
                let result: EditResult
                if replaceRange.length > 0 {
                    result = try EditingOps.replace(
                        range: replaceRange, with: completion, in: projection
                    )
                } else {
                    result = try EditingOps.insert(
                        completion, at: replaceRange.location, in: projection
                    )
                }
                suppressCompletion = true
                applyBlockModelResult(result, actionName: "Tag Completion")
                setSelectedRange(NSRange(location: finalPos, length: 0))
                return
            } catch {
                bmLog("⚠️ insertTagCompletion block-model path failed: \(error) — falling back to source-mode path")
                // fall through
            }
        }

        suppressCompletion = true

        if shouldChangeText(in: replaceRange, replacementString: word) {
            replaceCharacters(in: replaceRange, with: word)

            let spacePos = startPos + 1 + word.count
            if shouldChangeText(in: NSRange(location: spacePos, length: 0), replacementString: " ") {
                replaceCharacters(in: NSRange(location: spacePos, length: 0), with: " ")
            }

            didChangeText()

            setSelectedRange(NSRange(location: finalPos, length: 0))
        }
    }
    
    private func insertWikiCompletion(_ word: String, startPos: Int) {
        let text = string as NSString
        let currentPos = selectedRange().location

        let hasClosingBrackets = checkForClosingBrackets(at: currentPos, in: text)
        let replaceRange = NSRange(location: startPos, length: currentPos - startPos)
        let completion = hasClosingBrackets ? word : "\(word)]]"
        let newCursorPos = hasClosingBrackets
            ? startPos + word.count + 2   // past the existing ]]
            : startPos + completion.count  // right after inserted word+]]

        // Bug #33: route through the block-model pipeline when active.
        // The raw `replaceCharacters` + `didChangeText()` path below
        // bypasses the block-model projection, so the rendered
        // attributed string goes out of sync with storage and the
        // cursor visually lands on a new line after the link. When
        // `documentProjection` exists (markdown WYSIWYG mode),
        // `EditingOps.replace` / `.insert` produces a fresh projection
        // and `applyBlockModelResult` wires it into the live storage.
        if let projection = documentProjection {
            do {
                let result: EditResult
                if replaceRange.length > 0 {
                    result = try EditingOps.replace(
                        range: replaceRange, with: completion, in: projection
                    )
                } else {
                    result = try EditingOps.insert(
                        completion, at: startPos, in: projection
                    )
                }
                suppressCompletion = true
                applyBlockModelResult(result, actionName: "Wiki Link Completion")
                // Re-parse inlines so [[MyNote]] is detected as .wikilink.
                // applyBlockModelResult bypasses handleEditViaBlockModel's
                // reparse trigger, so we must call it explicitly.
                reparseCurrentBlockInlines()
                setSelectedRange(NSRange(location: newCursorPos, length: 0))
                return
            } catch {
                bmLog("⚠️ insertWikiCompletion block-model path failed: \(error) — falling back to source-mode path")
                // fall through
            }
        }

        suppressCompletion = true

        if shouldChangeText(in: replaceRange, replacementString: completion) {
            replaceCharacters(in: replaceRange, with: completion)
            didChangeText()
            setSelectedRange(NSRange(location: newCursorPos, length: 0))
        }
    }
    
    func calculateCompletionRange() -> NSRange {
        let location = selectedRange().location
        let context = detectCompletionContext()
        
        switch context {
        case .codeBlock(let startPos):
            return NSRange(location: startPos, length: location - startPos)
            
        case .tag(let startPos):
            return NSRange(location: startPos + 1, length: location - startPos - 1)
            
        case .wikiLink(let startPos):
            return NSRange(location: startPos, length: location - startPos)
            
        case .none:
            return NSRange(location: location, length: 0)
        }
    }
}

extension NSString {
    func safeSubstring(with range: NSRange) -> String {
        let length = self.length

        if length == 0 { return "" }

        let safeLocation = max(0, min(range.location, length - 1))
        let safeLength = max(0, min(range.length, length - safeLocation))

        if safeLength == 0 { return "" }

        let safeRange = NSRange(location: safeLocation, length: safeLength)
        return self.substring(with: safeRange)
    }
}
