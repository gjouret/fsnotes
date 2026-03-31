//
//  TextFormatter.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 3/6/18.
//  Copyright © 2018 Oleksandr Glushchenko. All rights reserved.
//

import Foundation

#if os(OSX)
    import Cocoa
    import Carbon.HIToolbox
    typealias Font = NSFont
    typealias TextView = NSTextView  // Decoupled: no longer references concrete EditTextView
    typealias Color = NSColor
#else
    import UIKit
    typealias Font = UIFont
    typealias TextView = UITextView  // Decoupled: no longer references concrete EditTextView
    typealias Color = UIColor
#endif

public class TextFormatter {
    private var attributedString: NSMutableAttributedString
    private var attributedSelected: NSAttributedString
    private var type: NoteType
    private var textView: TextView
    private var note: Note
    private var storage: NSTextStorage
    private var selectedRange: NSRange
    private var range: NSRange
    private var newSelectedRange: NSRange?
    private var cursor: Int?
    private let prefs: EditorPreferencesProvider

    private var prevSelectedString: NSAttributedString
    private var prevSelectedRange: NSRange
    
    private var isAutomaticQuoteSubstitutionEnabled: Bool = false
    private var isAutomaticDashSubstitutionEnabled: Bool = false
    
    init(textView: TextView, note: Note, prefs: EditorPreferencesProvider = EditorPreferences()) {
        self.prefs = prefs
        range = textView.selectedRange

        #if os(OSX)
            storage = textView.textStorage!
            attributedSelected = textView.attributedString()
            if textView.typingAttributes[.font] == nil {
                textView.typingAttributes[.font] = prefs.noteFont
            }
        #else
            storage = textView.textStorage
            attributedSelected = textView.attributedText
        #endif
        
        self.attributedString = NSMutableAttributedString(attributedString: attributedSelected.attributedSubstring(from: range))
        self.selectedRange = NSRange(0..<attributedString.length)
        
        self.type = note.type
        self.textView = textView
        self.note = note
        
        prevSelectedRange = range
        prevSelectedString = storage.attributedSubstring(from: prevSelectedRange)
        
        #if os(OSX)
            self.isAutomaticQuoteSubstitutionEnabled = textView.isAutomaticQuoteSubstitutionEnabled
            self.isAutomaticDashSubstitutionEnabled = textView.isAutomaticDashSubstitutionEnabled
        
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
        #endif
    }
    
    func getString() -> NSMutableAttributedString {
        return attributedString
    }
    
    func bold() { toggleMarkers(open: prefs.boldMarker, close: prefs.boldMarker) }
    func italic() { toggleMarkers(open: prefs.italicMarker, close: prefs.italicMarker) }
    public func underline() { toggleMarkers(open: "<u>", close: "</u>") }
    public func strike() { toggleMarkers(open: "~~", close: "~~") }
    public func highlight() { toggleMarkers(open: "<mark>", close: "</mark>") }

    /// Wrap the current selection with open/close markers. Apply-only — does NOT detect
    /// existing markers or toggle them off. Use toggleMarkers() for toggle behavior.
    /// Used by callers that always want to add markers (e.g., inserting a new link/image).
    public func wrapSelection(with open: String, close: String) {
        let string = attributedString.string
        let length = string.count

        var selectRange = NSMakeRange(range.location + open.count, 0)
        if length != 0 {
            selectRange = NSMakeRange(range.location, length + open.count + close.count)
        }

        insertText(open + string + close, selectRange: selectRange)
    }

    // MARK: - Unified Format Toggle

    /// Toggle markers around the cursor/selection. Handles ALL marker-based formatting:
    /// bold (**), italic (*), strikethrough (~~), underline (<u></u>), highlight (<mark></mark>).
    ///
    /// - If cursor/selection is inside existing markers → remove them, cursor at end of content
    /// - If not → wrap selection with markers
    public func toggleMarkers(open: String, close: String) {
        guard note.isMarkdown() else { return }

        let fullString = getAttributedString().string
        let nsStr = fullString as NSString
        let openLen = open.count
        let closeLen = close.count

        // --- Detection: is cursor/selection inside existing markers? ---

        // Strategy 1: Check characters immediately before/after the selection
        let expandedStart = max(0, range.location - openLen)
        let expandedEnd = min(nsStr.length, NSMaxRange(range) + closeLen)

        if expandedStart + openLen <= range.location && expandedEnd >= NSMaxRange(range) + closeLen {
            let before = nsStr.substring(with: NSRange(location: expandedStart, length: openLen))
            let after = nsStr.substring(with: NSRange(location: NSMaxRange(range), length: closeLen))

            // For bold, accept both ** and __ as markers
            let matchesBefore: Bool
            let matchesAfter: Bool
            if open == "**" {
                matchesBefore = (before == "**" || before == "__")
                matchesAfter = (after == "**" || after == "__")
            } else if open == "*" {
                matchesBefore = (before == "*" || before == "_")
                matchesAfter = (after == "*" || after == "_")
            } else {
                matchesBefore = (before == open)
                matchesAfter = (after == close)
            }

            if matchesBefore && matchesAfter {
                let fullRange = NSRange(location: expandedStart, length: expandedEnd - expandedStart)
                let content = nsStr.substring(with: range)
                insertText(content, replacementRange: fullRange,
                           selectRange: NSRange(location: expandedStart + content.count, length: 0))
                return
            }
        }

        // Strategy 2: No selection — search backward/forward from cursor for markers
        if range.length == 0 {
            let searchStart = max(0, range.location - 500)
            let searchEnd = min(nsStr.length, range.location + 500)

            let backRange = NSRange(location: searchStart,
                                    length: min(range.location - searchStart + openLen, nsStr.length - searchStart))
            let openMatch = nsStr.range(of: open, options: .backwards, range: backRange)

            if openMatch.location != NSNotFound {
                let fwdStart = range.location
                let fwdRange = NSRange(location: fwdStart,
                                       length: min(500, nsStr.length - fwdStart))
                let closeMatch = nsStr.range(of: close, range: fwdRange)

                if closeMatch.location != NSNotFound {
                    // Verify no intervening close marker between open and cursor
                    let betweenRange = NSRange(location: NSMaxRange(openMatch),
                                               length: range.location - NSMaxRange(openMatch))
                    let intervening = nsStr.range(of: close, range: betweenRange)

                    if intervening.location == NSNotFound {
                        let contentStart = NSMaxRange(openMatch)
                        let contentLen = closeMatch.location - contentStart
                        let content = nsStr.substring(with: NSRange(location: contentStart, length: contentLen))
                        let fullRange = NSRange(location: openMatch.location,
                                                length: NSMaxRange(closeMatch) - openMatch.location)
                        insertText(content, replacementRange: fullRange,
                                   selectRange: NSRange(location: openMatch.location + content.count, length: 0))
                        return
                    }
                }
            }
        }

        // --- Not inside markers: wrap selection ---
        let string = attributedString.string
        let length = string.count

        if length == 0 {
            // No selection — place cursor between markers
            insertText(open + close, selectRange: NSMakeRange(range.location + openLen, 0))
        } else {
            // Place cursor at end of wrapped text
            insertText(open + string + close,
                       selectRange: NSMakeRange(range.location + openLen + length + closeLen, 0))
        }
    }

    public func tab() {
        guard let pRange = getParagraphRange() else { return }
        
        var padding = "\t"
        
        if UserDefaultsManagement.indentUsing == 0x01 {
            padding = "  "
        }

        if UserDefaultsManagement.indentUsing == 0x02 {
            padding = "    "
        }
        
        let mutable = NSMutableAttributedString(attributedString: getAttributedString().attributedSubstring(from: pRange)).unloadTasks()

        let string = mutable.string
        var result = String()
        var addsChars = 0

        let location = textView.selectedRange.location
        let length = textView.selectedRange.length

        var isFirstLine = true
        string.enumerateLines { (line, _) in
            result.append(padding + line + "\n")

            if isFirstLine {
                isFirstLine = false
            } else {
                addsChars += padding.count
            }
        }

        let selectRange = NSRange(location: location + padding.count, length: length + addsChars)
        
        let mutableResult = NSMutableAttributedString(string: result)
        mutableResult.loadTasks()

        #if os(OSX)
            textView.textStorage?.removeAttribute(.todo, range: pRange)
        #else
            textView.textStorage.removeAttribute(.todo, range: pRange)

            // Fixes font size issue #1271
            let parFont = NotesTextProcessor.font
            let parRange = NSRange(location: 0, length:   mutableResult.length)
            mutableResult.addAttribute(.font, value: parFont, range: parRange)
            mutableResult.fixAttributes(in: parRange)
        #endif

        insertText(mutableResult, replacementRange: pRange, selectRange: selectRange)
    }
    
    public func unTab() {
        guard let pRange = getParagraphRange() else { return }

        let mutable = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: pRange)).unloadTasks()
        let string = mutable.string

        var result = String()

        let location = textView.selectedRange.location
        let length = textView.selectedRange.length

        var padding = 0
        var dropChars = 0

        if string.starts(with: "\t") {
            padding = 1
        } else if string.starts(with: "  ") && UserDefaultsManagement.indentUsing == 0x01 {
            padding = 2
        } else if string.starts(with: "    ") {
            padding = 4
        }

        if padding == 0 {
            return
        }

        var isFirstLine = true
        
        string.enumerateLines { (line, _) in
            var line = line

            if !line.isEmpty {
                var firstCharsToDrop: Int?
                
                if line.first == "\t" {
                    firstCharsToDrop = 1
                } else if UserDefaultsManagement.indentUsing == 0x01 && line.starts(with: "  ") {
                    firstCharsToDrop = 2
                } else if line.starts(with: "    ") {
                    firstCharsToDrop = 4
                }
                
                if let x = firstCharsToDrop {
                    line = String(line.dropFirst(x))
                    
                    if length == 0 {
                        dropChars = 0
                    } else {
                        if isFirstLine {
                            isFirstLine = false
                        } else {
                            dropChars += x
                        }
                    }
                }
            }
            
            result.append(line + "\n")
        }

        let diffLocation = location - padding
        
        var selectLength = length - dropChars
        var selectLocation = diffLocation > 0 ? diffLocation : 0

        if selectLocation < pRange.location {
            selectLocation = pRange.location
        }

        if selectLength > result.count {
            selectLength = result.count
        }

        let selectRange = NSRange(location: selectLocation, length: selectLength)
        let mutableResult = NSMutableAttributedString(string: result)
        mutableResult.loadTasks()

        #if os(OSX)
            textView.textStorage?.removeAttribute(.todo, range: pRange)
        #else
            textView.textStorage.removeAttribute(.todo, range: pRange)

            // Fixes font size issue #1271
            let parFont = NotesTextProcessor.font
            let parRange = NSRange(location: 0, length:   mutableResult.length)
            mutableResult.addAttribute(.font, value: parFont, range: parRange)
            mutableResult.fixAttributes(in: parRange)
        #endif

        insertText(mutableResult, replacementRange: pRange, selectRange: selectRange)
    }
    
    public func header(_ string: String) {
        let fullSelection = selectedRange.length > 0
        guard let pRange = getParagraphRange() else { return }

#if os(iOS)
        var prefix = String()
        var paragraph = storage.mutableString.substring(with: pRange)

        if paragraph.starts(with: "######") {
            paragraph = paragraph
                .replacingOccurrences(of: "#", with: "")
                .trimSpaces()
        } else if paragraph.starts(with: "#") {
            prefix = string
        } else {
            prefix = string + " "
        }

        let diff = paragraph.contains("\n") ? 1 : 0
        let selectRange = NSRange(location: pRange.location + (prefix + paragraph).count - diff, length: 0)
        insertText(prefix + paragraph, replacementRange: pRange, selectRange: selectRange)
#else
        let prefix = string + " "
        var paragraph = storage.mutableString
            .substring(with: pRange)

        if paragraph.starts(with: prefix) {
            paragraph = paragraph.replacingOccurrences(of: prefix, with: "")
        } else {
            paragraph =
                prefix + paragraph.replacingOccurrences(of: "#", with: "").trimSpaces()
        }

        let diff = paragraph.contains("\n") ? 1 : 0

        var selectRange = NSRange(location: pRange.location + paragraph.count - diff, length: 0)

        if fullSelection {
            selectRange = NSRange(location: pRange.location, length: paragraph.count - diff)
        }

        insertText(paragraph, replacementRange: pRange, selectRange: selectRange)
#endif
    }
    
    public func link() {
        textView.undoManager?.beginUndoGrouping()

        let text = "[" + attributedString.string + "]()"
        replaceWith(string: text, range: range)
        
        if (attributedString.length == 4) {
            setSelectedRange(NSMakeRange(range.location + 1, 0))
        } else {
            setSelectedRange(NSMakeRange(range.upperBound + 3, 0))
        }

        textView.undoManager?.endUndoGrouping()
    }

    public func wikiLink() {
        textView.undoManager?.beginUndoGrouping()

        let text = "[[" + attributedString.string + "]]"
        replaceWith(string: text, range: range)

        if (text.count == 4) {
            setSelectedRange(NSMakeRange(range.location + 2, 0))

            #if os(OSX)
            textView.complete(nil)
            #endif
        } else {
            setSelectedRange(NSMakeRange(range.location + 2, text.count - 4))
        }

        textView.undoManager?.endUndoGrouping()
    }

    public func image() {
        textView.undoManager?.beginUndoGrouping()

        let text = "![" + attributedString.string + "]()"
        replaceWith(string: text)
        
        if (attributedString.length == 5) {
            setSelectedRange(NSMakeRange(range.location + 2, 0))
        } else {
            setSelectedRange(NSMakeRange(range.upperBound + 4, 0))
        }

        textView.undoManager?.endUndoGrouping()
    }
    
    public func isListParagraph() -> Bool {
        guard let currentPR = getParagraphRange() else { return false }
        let paragraph = storage.attributedSubstring(from: currentPR)
        
        if TextFormatter.getAutocompleteCharsMatch(string: paragraph.string) != nil {
            return true
        }

        if TextFormatter.getAutocompleteDigitsMatch(string: paragraph.string) != nil {
            return true
        }
        
        if paragraph.hasTodoAttribute() {
            return true
        }
        
        return false
    }

    public func tabKey() {
        guard let currentPR = getParagraphRange() else { return }
        let paragraph = storage.attributedSubstring(from: currentPR).string
        let sRange = self.textView.selectedRange
        
        // Middle
        if (sRange.location != 0 || sRange.location != storage.length)
            && paragraph.count == 1
            && self.note.isMarkdown()
        {
            self.insertText("\t", replacementRange: sRange)
            return
        }
        
        // First & Last
        if (sRange.location == 0 || sRange.location == self.storage.length) && paragraph.count == 0 && self.note.isMarkdown() {
            self.insertText("\t\n", replacementRange: sRange)
            self.setSelectedRange(NSRange(location: sRange.location + 1, length: 0))
            return
        }
        
        self.insertText("\t")
    }

    public static func getAutocompleteCharsMatch(string: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern:
            "^(( |\t)*\\- \\[[x| ]*\\] )|^(( |\t)*[-|–|—|*|•|>|\\+]{1} )"), let result = regex.firstMatch(in: string, range: NSRange(0..<string.count)) else { return nil }

        return result
    }

    public static func getAutocompleteDigitsMatch(string: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: "^(( |\t)*[0-9]+\\. )"), let result = regex.firstMatch(in: string, range: NSRange(0..<string.count)) else { return nil }

        return result
    }

    private func matchChars(string: NSAttributedString, match: NSTextCheckingResult, prefix: String? = nil) {
        guard string.length >= match.range.upperBound else { return }

        let found = string.attributedSubstring(from: match.range).string

        // Check if the line is empty (only the prefix, no content)
        // Strip prefix and whitespace/newlines — if nothing left, exit the mode
        let content = string.string
            .replacingOccurrences(of: found, with: "", options: [], range: string.string.startIndex..<string.string.endIndex)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if content.isEmpty {
            let range = storage.mutableString.paragraphRange(for: textView.selectedRange)
            let selectRange = NSRange(location: range.location, length: 0)
            insertText("\n", replacementRange: range, selectRange: selectRange)
        } else {
            insertText("\n" + found)
        }

        updateCurrentParagraph()
    }

    private func matchDigits(string: NSAttributedString, match: NSTextCheckingResult) {
        guard string.length >= match.range.upperBound else { return }

        let found = string.attributedSubstring(from: match.range).string
        var newLine = 1

        if textView.selectedRange.upperBound == storage.length {
            newLine = 0
        }

        if found.count + newLine == string.length {
            let range = storage.mutableString.paragraphRange(for: textView.selectedRange)
            let selectRange = NSRange(location: range.location, length: 0)
            insertText("\n", replacementRange: range, selectRange: selectRange)
        } else if let position = Int(found.replacingOccurrences(of:"[^0-9]", with: "", options: .regularExpression)) {
            let newDigit = found.replacingOccurrences(of: String(position), with: String(position + 1))
            insertText("\n" + newDigit)
        }

        updateCurrentParagraph()
    }

    private func updateCurrentParagraph() {
        let parRange = getParagraphRange(for: textView.selectedRange.location)

        #if os(iOS)
            textView.textStorage.updateParagraphStyle(range: parRange)
        #else
            textView.textStorage?.updateParagraphStyle(range: parRange)
        #endif
    }

    // MARK: - Return Key State Machine

    /// What should happen when Return is pressed on the current line.
    public enum NewLineTransition: Equatable {
        /// Plain newline, reset typing attributes to body font
        case bodyText
        /// Continue checkbox list: \n + indent + unchecked checkbox
        case continueCheckbox(prefix: String, todoLocation: Int)
        /// Continue unordered list: \n + matched prefix (e.g. "  - ")
        case continueUnorderedList(prefix: String)
        /// Continue numbered list: \n + incremented prefix (e.g. "2. ")
        case continueNumberedList(next: String)
        /// Continue indentation: \n + tabs/spaces
        case continueIndent(prefix: String)
        /// Exit list: delete empty bullet line, insert plain newline
        case exitList(paragraphRange: NSRange)
        /// Exit todo: special handling for empty checkbox near cursor
        case exitTodo(paragraphRange: NSRange)
    }

    /// Pure function: determine what transition to apply when Return is pressed.
    /// Reads the paragraph content and cursor position, returns the transition.
    public static func newLineTransition(
        paragraph: NSAttributedString,
        paragraphRange: NSRange,
        cursorLocation: Int,
        storageLength: Int
    ) -> NewLineTransition {
        let selectedRange = NSRange(location: cursorLocation, length: 0)
        let paragraphString = paragraph.string
        let cursorNearEnd = cursorLocation != paragraphRange.location
            && paragraphRange.upperBound - 2 < cursorLocation

        // --- 1. Checkbox (todo) ---
        if paragraph.length >= 2 {
            // Check if paragraph has a todo attribute (checkbox)
            var hasTodo = false
            paragraph.enumerateAttribute(.todo, in: NSRange(0..<paragraph.length), options: []) { value, _, stop in
                if value != nil { hasTodo = true; stop.pointee = true }
            }

            if hasTodo {
                // Check if the line is empty (only checkbox + space, no text content).
                // Same pattern as bullet/numbered lists: empty marker → exit list.
                let content = paragraphString
                    .replacingOccurrences(of: "\u{FFFC}", with: "")  // Remove attachment char
                    .replacingOccurrences(of: "- [ ] ", with: "")     // Remove raw markdown
                    .replacingOccurrences(of: "- [x] ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if content.isEmpty {
                    return .exitTodo(paragraphRange: paragraphRange)
                }
            }

            // Check if paragraph has a todo attribute anywhere
            var todoLocation = -1
            paragraph.enumerateAttribute(.todo, in: NSRange(0..<paragraph.length), options: []) { value, range, stop in
                guard value != nil else { return }
                todoLocation = range.location
                stop.pointee = true
            }

            if todoLocation > -1 {
                let prefix = todoLocation > 0
                    ? paragraph.attributedSubstring(from: NSRange(0..<todoLocation)).string
                    : ""
                return .continueCheckbox(prefix: prefix, todoLocation: todoLocation)
            }
        }

        // --- 2. Unordered list ---
        if cursorNearEnd {
            if let charsMatch = getAutocompleteCharsMatch(string: paragraphString) {
                let found = (paragraphString as NSString).substring(with: charsMatch.range)
                let content = paragraphString
                    .replacingOccurrences(of: found, with: "", options: [], range: paragraphString.startIndex..<paragraphString.endIndex)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if content.isEmpty {
                    return .exitList(paragraphRange: paragraphRange)
                } else {
                    return .continueUnorderedList(prefix: found)
                }
            }

            // --- 3. Numbered list ---
            if let digitsMatch = getAutocompleteDigitsMatch(string: paragraphString) {
                let found = (paragraphString as NSString).substring(with: digitsMatch.range)
                var newLine = 1
                if cursorLocation == storageLength { newLine = 0 }

                if found.count + newLine == paragraph.length {
                    return .exitList(paragraphRange: paragraphRange)
                } else if let position = Int(found.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)) {
                    let next = found.replacingOccurrences(of: String(position), with: String(position + 1))
                    return .continueNumberedList(next: next)
                }
            }
        }

        // --- 4. Heading ---
        if paragraphString.starts(with: "#") {
            return .bodyText
        }

        // --- 5. Indentation ---
        if paragraphString.starts(with: "\t"),
           let prefix = paragraphString.getPrefixMatchSequentially(char: "\t"),
           cursorLocation != paragraphRange.location {
            return .continueIndent(prefix: prefix)
        }
        if paragraphString.starts(with: "  "),
           let prefix = paragraphString.getPrefixMatchSequentially(char: " "),
           cursorLocation != paragraphRange.location {
            return .continueIndent(prefix: prefix)
        }

        // --- 6. Default ---
        return .bodyText
    }

    /// Execute the transition: insert text, set typing attributes, position cursor.
    private func applyTransition(_ transition: NewLineTransition) {
        switch transition {

        case .bodyText:
            #if os(OSX)
            (textView as? EditTextView)?.suppressCompletion = true
            textView.insertNewline(nil)
            #else
            textView.insertText("\n")
            #endif

        case .continueCheckbox(let prefix, _):
            let unchecked = AttributedBox.getUnChecked()?.attributedSubstring(from: NSRange(0..<2))
            #if os(OSX)
            let string = NSMutableAttributedString(string: "\n" + prefix)
            string.append(unchecked!)
            self.insertText(string)
            #else
            let selectedRange = textView.selectedRange
            let selectedTextRange = textView.selectedTextRange!
            let checkbox = NSMutableAttributedString(string: "\n" + prefix)
            checkbox.append(unchecked!)
            textView.undoManager?.beginUndoGrouping()
            textView.replace(selectedTextRange, withText: checkbox.string)
            textView.textStorage.replaceCharacters(in: NSRange(location: selectedRange.location, length: checkbox.length), with: checkbox)
            textView.undoManager?.endUndoGrouping()
            #endif

        case .continueUnorderedList(let prefix):
            insertText("\n" + prefix)
            updateCurrentParagraph()

        case .continueNumberedList(let next):
            insertText("\n" + next)
            updateCurrentParagraph()

        case .continueIndent(let prefix):
            let string = TextFormatter.getAttributedCode(string: "\n" + prefix)
            self.insertText(string)

        case .exitList(let paragraphRange):
            let range = storage.mutableString.paragraphRange(for: textView.selectedRange)
            let selectRange = NSRange(location: range.location, length: 0)
            insertText("\n", replacementRange: range, selectRange: selectRange)
            updateCurrentParagraph()

        case .exitTodo(let paragraphRange):
            let selectRange = NSRange(location: paragraphRange.location, length: 0)
            insertText("", replacementRange: paragraphRange, selectRange: selectRange)
            #if os(OSX)
            textView.insertNewline(nil)
            textView.setSelectedRange(selectRange)
            #else
            textView.insertText("\n")
            textView.selectedRange = selectRange
            #endif
        }
    }

    public func newLine() {
        guard let paragraphRange = getParagraphRange() else { return }
        let paragraph = storage.attributedSubstring(from: paragraphRange)
        let transition = Self.newLineTransition(
            paragraph: paragraph,
            paragraphRange: paragraphRange,
            cursorLocation: textView.selectedRange.location,
            storageLength: storage.length
        )
        applyTransition(transition)

        #if os(OSX)
        // After the transition completes (including all synchronous didProcessEditing
        // cycles), set typing attributes to match the target state. This is the state
        // machine's final output — it defines what the cursor line looks like before
        // the user types their first character.
        //
        // For "continue" transitions: copy paragraph style from the line we just left
        // (it has the correct indent/spacing from the previous phase5+BulletProcessor cycle).
        //
        // For "exit" transitions: use body paragraph style.
        let cursorPos = textView.selectedRange.location
        switch transition {
        case .bodyText, .exitList, .exitTodo:
            let bodyParagraph = NSMutableParagraphStyle()
            bodyParagraph.lineSpacing = CGFloat(UserDefaultsManagement.editorLineSpacing)
            bodyParagraph.paragraphSpacing = 0
            bodyParagraph.paragraphSpacingBefore = 0
            textView.typingAttributes = [
                .font: prefs.noteFont,
                .foregroundColor: NotesTextProcessor.fontColor,
                .paragraphStyle: bodyParagraph
            ]
        case .continueUnorderedList, .continueNumberedList, .continueCheckbox, .continueIndent:
            // The previous line has the correct style — copy it to typing attributes
            if cursorPos > 1,
               let paraStyle = storage.attribute(.paragraphStyle, at: cursorPos - 2, effectiveRange: nil) as? NSParagraphStyle {
                var attrs = textView.typingAttributes
                attrs[.paragraphStyle] = paraStyle
                textView.typingAttributes = attrs
            }
        }
        #endif
    }

    public func todo() {
        guard let pRange = getParagraphRange() else { return }

        let attributedString = getAttributedString().attributedSubstring(from: pRange)
        let mutable = NSMutableAttributedString(attributedString: attributedString).unloadTasks()

        if !attributedString.hasTodoAttribute() && selectedRange.length == 0 {
            var offset = 0
            let symbols = ["\t", " "]
            for char in mutable.string {
                if symbols.contains(String(char)) {
                    offset += 1
                } else {
                    break
                }
            }

            let insertRange = NSRange(location: pRange.location + offset, length: 0)
            let selectRange = NSRange(location: range.location + 2, length: range.length)
            insertText(AttributedBox.getUnChecked()!, replacementRange: insertRange, selectRange: selectRange)
            #if os(OSX)
            // Set clean typing attributes so text typed after the checkbox
            // doesn't inherit stale attributes (negative kern, wrong color).
            textView.typingAttributes = [
                .font: prefs.noteFont,
                .foregroundColor: NotesTextProcessor.fontColor
            ]
            #endif
            return
        }

        var lines = [String]()
        var addPrefixes = false
        var addCompleted = false
        let string = mutable.string

        string.enumerateLines { (line, _) in
            let result = self.parseTodo(line: line)
            addPrefixes = !result.0
            addCompleted = result.1
            lines.append(result.2)
        }

        var result = String()
        for line in lines {

            // Removes extra chars identified as list items start
            var line = line

            let digitRegex = try! NSRegularExpression(pattern: "^([0-9]+\\. )")
            let digitRegexResult = digitRegex.firstMatch(in: line, range: NSRange(0..<line.count))

            let charRegex = try! NSRegularExpression(pattern: "^([-*–+]+ )")
            let charRegexResult = charRegex.firstMatch(in: line, range: NSRange(0..<line.count))

            if let result = digitRegexResult {
                let qty = result.range.length
                line = String(line.dropFirst(qty))
            } else if let result = charRegexResult, !line.contains("- [") {
                let qty = result.range.length
                line = String(line.dropFirst(qty))
            }

            if addPrefixes {
                let task = addCompleted ? "- [x] " : "- [ ] "
                var empty = String()
                var scanFinished = false

                if line.count > 0 {
                    var j = 0
                    for char in line {
                        j += 1

                        if (char.isWhitespace || char == "\t")
                            && !scanFinished {
                            if j == line.count {
                                empty.append("\(char)" + task)
                            } else {
                                empty.append(char)
                            }
                        } else {
                            if !scanFinished {
                                empty.append(task + "\(char)")
                                scanFinished = true
                            } else {
                                empty.append(char)
                            }
                        }
                    }

                    result += empty + "\n"
                } else {
                    result += task + "\n"
                }
            } else {
                result += line + "\n"
            }
        }

        let mutableResult = NSMutableAttributedString(string: result)
        
        #if os(iOS)
            let textColor: UIColor = UIColor.blackWhite
        #else
            let textColor: NSColor = NotesTextProcessor.fontColor
        #endif
        
        mutableResult.addAttribute(.foregroundColor, value: textColor, range: NSRange(location: 0, length: mutableResult.length))
        mutableResult.addAttribute(.font, value: NotesTextProcessor.font, range: NSRange(location: 0, length: mutableResult.length))
        mutableResult.fixAttributes(in: NSRange(location: 0, length: mutableResult.length))
        mutableResult.loadTasks()

        let diff = mutableResult.length - attributedString.length
        let selectRange = selectedRange.length == 0 || lines.count == 1
            ? NSRange(location: pRange.location + pRange.length + diff - 1, length: 0)
            : NSRange(location: pRange.location, length: mutableResult.length)
        
        // Fixes clicked area
        storage.removeAttribute(.todo, range: pRange)

        insertText(mutableResult, replacementRange: pRange, selectRange: selectRange)
    }

    public func toggleTodo(_ location: Int? = nil) {
        if let location = location, let todoAttr = storage.attribute(.todo, at: location, effectiveRange: nil) as? Int {
            #if os(OSX)
                if textView.window?.firstResponder != textView {
                    textView.window?.makeFirstResponder(textView)
                }
                // Save scroll position to prevent jump on paragraph replacement
                let savedVisibleRect = textView.enclosingScrollView?.contentView.bounds
            #endif

            guard let paragraph = getParagraphRange(for: location) else { return }
            let paragraphTextNonMutable = storage.attributedSubstring(from: paragraph)
            let paragraphText = NSMutableAttributedString(attributedString: paragraphTextNonMutable)
            
            let attributedText = (todoAttr == 0) ?
                AttributedBox.getChecked(clean: true) :
                AttributedBox.getUnChecked(clean: true)
            
            let checkboxLocation = location - paragraph.location
            paragraphText.replaceCharacters(in: NSRange(location: checkboxLocation, length: 1), with: attributedText!)
            
            if todoAttr == 0 {
                paragraphText.addAttribute(.strikethroughStyle, value: 1, range: NSRange(location: 0, length: paragraphText.length))
                textView.typingAttributes[.strikethroughStyle] = 1
            } else {
                paragraphText.removeAttribute(.strikethroughStyle, range: NSRange(location: 0, length: paragraphText.length))
                textView.typingAttributes.removeValue(forKey: .strikethroughStyle)
            }

            // Preserve headIndent for proper text wrapping + consistent line height
            let parStyle = NSMutableParagraphStyle()
            parStyle.lineSpacing = CGFloat(Float(prefs.editorLineSpacing))
            let markerWidth = ("- [ ] " as NSString).size(withAttributes: [.font: NotesTextProcessor.font]).width
            parStyle.headIndent = markerWidth
            paragraphText.addAttribute(.paragraphStyle, value: parStyle, range: NSRange(location: 0, length: paragraphText.length))

            insertText(paragraphText, replacementRange: paragraph)

            if todoAttr == 1 {
                storage.removeAttribute(.strikethroughStyle, range: paragraph)
            }

            #if os(OSX)
                // Restore scroll position after paragraph replacement
                if let rect = savedVisibleRect {
                    textView.enclosingScrollView?.contentView.scroll(to: rect.origin)
                    textView.enclosingScrollView?.reflectScrolledClipView(textView.enclosingScrollView!.contentView)
                }
            #endif

            updateCurrentParagraph()
            
            return
        }

        guard let paragraphRange = getParagraphRange() else { return }
        let paragraph = self.storage.attributedSubstring(from: paragraphRange)
        
        if let index = paragraph.string.range(of: "- [ ] ") {
            let local = paragraph.string.nsRange(from: index).location
            let range = NSMakeRange(paragraphRange.location + local, 6)
            if let attributedText = AttributedBox.getChecked() {
                self.insertText(attributedText, replacementRange: range)
            }
            
            return

        } else if let index = paragraph.string.range(of: "- [x] ") {
            let local = paragraph.string.nsRange(from: index).location
            let range = NSMakeRange(paragraphRange.location + local, 6)
            if let attributedText = AttributedBox.getUnChecked() {
                self.insertText(attributedText, replacementRange: range)
            }
            
            return
        }
    }

    public func backTick() {
        let selectedRange = textView.selectedRange

        if selectedRange.length > 0 {
            let text = storage.attributedSubstring(from: selectedRange).string
            let string = "`\(text)`"
            let codeFont = prefs.codeFont

            let mutableString = NSMutableAttributedString(string: string)
            mutableString.addAttribute(.font, value: codeFont, range: NSRange(0..<string.count))
            mutableString.fixAttributes(in: NSRange(0..<string.count))

            insertText(mutableString, replacementRange: selectedRange)
            return
        }

        insertText("``")
        setSelectedRange(NSRange(location: selectedRange.location, length: selectedRange.length + 1))
    }

    public func codeBlock() {
        let currentRange = textView.selectedRange
        if currentRange.length > 0 {
            let substring = storage.attributedSubstring(from: currentRange)
            let mutable = NSMutableAttributedString(string: "```\n")
            mutable.append(substring)

            if substring.string.last != "\n" {
                mutable.append(NSAttributedString(string: "\n"))
            }

            mutable.append(NSAttributedString(string: "```\n"))

            insertText(mutable.string, replacementRange: currentRange)
            // Place cursor inside the code block content area
            setSelectedRange(NSRange(location: currentRange.location + 4, length: 0))
            return
        }

        insertText("```\n\n```\n")
        setSelectedRange(NSRange(location: currentRange.location + 4, length: 0))
    }

    public func quote() {
        guard let pRange = getParagraphRange() else { return }
        let paragraph = storage.mutableString.substring(with: pRange)

        guard paragraph.isContainsLetters else {
            insertText("> ")
            return
        }

        var hasPrefix = false
        var lines = [String]()

        paragraph.enumerateLines { (line, _) in
            hasPrefix = line.starts(with: "> ")

            var skipNext = false
            var scanFinished = false
            var cleanLine = String()

            for char in line {
                if skipNext {
                    skipNext = false
                    continue
                }

                if char == ">" && !scanFinished {
                    skipNext = true
                    scanFinished = true
                } else {
                    cleanLine.append(char)
                }
            }

            lines.append(cleanLine)
        }

        var result = String()
        for line in lines {
            if hasPrefix {
                result += line + "\n"
            } else {
                result += "> " + line + "\n"
            }
        }

        let selectRange = selectedRange.length == 0 || lines.count == 1
            ? NSRange(location: pRange.location + result.count - 1, length: 0)
            : NSRange(location: pRange.location, length: result.count)

        insertText(result, replacementRange: pRange, selectRange: selectRange)
    }
    
    private func getAttributedTodoString(_ string: String) -> NSAttributedString {
        let string = NSMutableAttributedString(string: string)
        string.addAttribute(.foregroundColor, value: NotesTextProcessor.syntaxColor, range: NSRange(0..<1))

        var color = Color.black

        #if os(OSX)
            color = NSColor(named: "mainText")!
        #endif

        string.addAttribute(.foregroundColor, value: color, range: NSRange(1..<string.length))
        return string
    }
    
    private func replaceWith(string: String, range: NSRange? = nil) {
        #if os(iOS)
            var selectedRange: UITextRange
        
            if let range = range,
                let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                let end = textView.position(from: start, offset: range.length),
                let sRange = textView.textRange(from: start, to: end) {
                selectedRange = sRange
            } else {
                selectedRange = textView.selectedTextRange!
            }

            textView.replace(selectedRange, withText: string)
        #else
            var r = textView.selectedRange
            if let range = range {
                r = range
            }
        
            textView.insertText(string, replacementRange: r)
        #endif
    }
    
    deinit {
        #if os(OSX)
            textView.isAutomaticQuoteSubstitutionEnabled = self.isAutomaticQuoteSubstitutionEnabled
            textView.isAutomaticDashSubstitutionEnabled = self.isAutomaticDashSubstitutionEnabled
        #endif

        setTypingAttributes(font: prefs.noteFont)
        var text: NSAttributedString?

        #if os(OSX)
            text = textView.attributedString()
        #else
            text = textView.attributedText
        #endif

        if let attributed = text {
            note.save(attributed: attributed)
        }

        #if os(iOS)
            textView.initUndoRedoButons()
        #endif
    }
    
    func getParagraphRange() -> NSRange? {
        if range.upperBound <= storage.length {
            let paragraph = storage.mutableString.paragraphRange(for: range)
            return paragraph
        }
        
        return nil
    }
    
    private func getParagraphRange(for location: Int) -> NSRange? {
        guard location <= storage.length else { return nil}

        let range = NSRange(location: location, length: 0)
        let paragraphRange = storage.mutableString.paragraphRange(for: range)
        
        return paragraphRange
    }
            
    func getTypingAttributes() -> Font {
        #if os(OSX)
            return textView.typingAttributes[.font] as! Font
        #else
            if let typingFont = textView.typingFont {
                textView.typingFont = nil
                return typingFont
            }

            guard textView.textStorage.length > 0, textView.selectedRange.location > 0 else { return prefs.noteFont }

            let i = textView.selectedRange.location - 1
            let upper = textView.selectedRange.upperBound
            let substring = textView.attributedText.attributedSubstring(from: NSRange(i..<upper))

            if let prevFont = substring.attribute(.font, at: 0, effectiveRange: nil) as? UIFont {
                return prevFont
            }

            return prefs.noteFont
        #endif
    }

    #if os(OSX)
    private func getDefaultColor() -> NSColor {
        var color = NSColor(named: "mainText")!
        
        return color
    }
    #endif
    
    func setTypingAttributes(font: Font) {
        #if os(OSX)
            textView.typingAttributes[.font] = font
        #else
            textView.typingFont = font
            textView.typingAttributes[.font] = font
        #endif
    }
        
    public func setSelectedRange(_ range: NSRange) {
        #if os(OSX)
            if range.upperBound <= storage.length {
                textView.setSelectedRange(range)
            }
        #else
            textView.selectedRange = range
        #endif
    }
    
    func getAttributedString() -> NSAttributedString {
        #if os(OSX)
            return textView.attributedString()
        #else
            return textView.attributedText
        #endif
    }
    
    private func insertText(_ string: Any, replacementRange: NSRange? = nil, selectRange: NSRange? = nil) {
        let range = replacementRange ?? self.textView.selectedRange
        
    #if os(iOS)
        guard
            let start = textView.position(from: self.textView.beginningOfDocument, offset: range.location),
            let end = textView.position(from: start, offset: range.length),
            let selectedRange = textView.textRange(from: start, to: end)
        else { return }
    
        var replaceString = String()
        if let attributedString = string as? NSAttributedString {
            replaceString = attributedString.string
        }

        if let plainString = string as? String {
            replaceString = plainString
        }

        self.textView.undoManager?.beginUndoGrouping()
        self.textView.replace(selectedRange, withText: replaceString)

        if let string = string as? NSAttributedString {
            let editedRange = NSRange(location: range.location, length: replaceString.count)
            storage.replaceCharacters(in: editedRange, with: string)
            storage.delegate?.textStorage!(storage, didProcessEditing: NSTextStorage.EditActions.editedCharacters, range: editedRange, changeInLength: 1)
        } else {
            let parRange = NSRange(location: range.location, length: replaceString.count)
            let parStyle = NSMutableParagraphStyle()
            parStyle.alignment = .left
            parStyle.lineSpacing = CGFloat(Float(prefs.editorLineSpacing))
            self.textView.textStorage.addAttribute(.paragraphStyle, value: parStyle, range: parRange)
        }

        self.textView.undoManager?.endUndoGrouping()
    #else
        textView.insertText(string, replacementRange: range)
    #endif
        
        if let select = selectRange {
            setSelectedRange(select)
        }
    }

    public static func getAttributedCode(string: String) -> NSMutableAttributedString {
        let attributedString = NSMutableAttributedString(string: string)
        let range = NSRange(0..<attributedString.length)

        attributedString.addAttribute(.font, value: NotesTextProcessor.codeFont as Any, range: range)
        attributedString.fixAttributes(in: range)
        return attributedString
    }

    public func list() {
        guard let pRange = getParagraphRange() else { return }

        let attributedString = getAttributedString().attributedSubstring(from: pRange)
        let mutable = NSMutableAttributedString(attributedString: attributedString)
        let string = mutable.unloadTasks().string

        guard string.isContainsLetters else {
            insertText("- ")
            return
        }

        var lines = [String]()
        var addPrefixes = false

        string.enumerateLines { (line, _) in
            addPrefixes = !self.hasPrefix(line: line, numbers: false)
            let cleanLine = self.cleanListItem(line: line)
            lines.append(cleanLine)
        }

        var result = String()
        for line in lines {
            if addPrefixes {
                var empty = String()
                var scanFinished = false

                for char in line {
                    if char.isWhitespace && !scanFinished {
                        empty.append(char)
                    } else {
                        if !scanFinished {
                            empty.append("- \(char)")
                            scanFinished = true
                        } else {
                            empty.append(char)
                        }
                    }
                }

                result += empty + "\n"
            } else {
                result += line + "\n"
            }
        }

        let selectRange = selectedRange.length == 0 || lines.count == 1
            ? NSRange(location: pRange.location + result.count - 1, length: 0)
            : NSRange(location: pRange.location, length: result.count)
        
        reset(pRange: pRange)
        insertText(result, replacementRange: pRange, selectRange: selectRange)
        
        // Fixes small font bug
        //storage.addAttribute(.font, value: NotesTextProcessor.font, range: NSRange(location: pRange.location, length: result.count))
    }

    public func orderedList() {
        guard let pRange = getParagraphRange() else { return }

        let attributedString = getAttributedString().attributedSubstring(from: pRange)
        let mutable = NSMutableAttributedString(attributedString: attributedString)
        let string = mutable.unloadTasks().string

        guard string.isContainsLetters else {
            insertText("1. ")
            return
        }

        var lines = [String]()
        var addPrefixes = false

        string.enumerateLines { (line, _) in
            addPrefixes = !self.hasPrefix(line: line, numbers: true)
            let cleanLine = self.cleanListItem(line: line)
            lines.append(cleanLine)
        }

        var result = String()
        var i = 1
        var deep = 0

        for line in lines {
            if addPrefixes {
                var empty = String()
                var scanFinished = false
                var lineDeep = 0

                for char in line {
                    if char.isWhitespace && !scanFinished {
                        empty.append(char)
                        lineDeep += 1
                    } else {
                        if !scanFinished {

                            // Resets numeration on deeper lvl
                            if lineDeep != deep {
                                i = 1
                                deep = lineDeep
                            }

                            empty.append("\(i). \(char)")
                            scanFinished = true
                        } else {
                            empty.append(char)
                        }
                    }
                }


                result += empty + "\n"
                i += 1
            } else {
                result += line + "\n"
            }
        }

        let selectRange = selectedRange.length == 0 || lines.count == 1
            ? NSRange(location: pRange.location + result.count - 1, length: 0)
            : NSRange(location: pRange.location, length: result.count)

        reset(pRange: pRange)
        insertText(result, replacementRange: pRange, selectRange: selectRange)
        
        // Fixes small font bug
        //storage.addAttribute(.font, value: NotesTextProcessor.font, range: NSRange(location: pRange.location, length: result.count))
    }
    
    private func reset(pRange: NSRange) {
        storage.removeAttribute(.strikethroughStyle, range: pRange)
        storage.removeAttribute(.todo, range: pRange)
    }

    private func cleanListItem(line: String) -> String {
        var line = line

        let digitRegex = try! NSRegularExpression(pattern: "^([0-9]+\\. )")
        let digitRegexResult = digitRegex.firstMatch(in: line, range: NSRange(0..<line.count))

        let charRegex = try! NSRegularExpression(pattern: "^([-*–+]+ )")
        let charRegexResult = charRegex.firstMatch(in: line, range: NSRange(0..<line.count))

        if line.starts(with: "- [ ] ") || line.starts(with: "- [x] ") {
            line = String(line.dropFirst(6))
        } else if let result = digitRegexResult {
            let qty = result.range.length
            line = String(line.dropFirst(qty))
        } else if let result = charRegexResult, !line.contains("- [") {
            let qty = result.range.length
            line = String(line.dropFirst(qty))
        }

        return line
    }

    private func parseTodo(line: String) -> (Bool, Bool, String) {
        var count = 0
        var hasTodoPrefix = false
        var hasIncompletedTask = false
        var charFound = false
        var whitespacePrefix = String()
        var letterPrefix = String()

        for char in line {
            if char.isWhitespace && !charFound {
                count += 1
                whitespacePrefix.append(char)
                continue
            } else {
                charFound = true
                letterPrefix.append(char)
            }
        }

        if letterPrefix.starts(with: "- [ ] ") {
            hasTodoPrefix = false
            hasIncompletedTask = true
        }

        if letterPrefix.starts(with: "- [x] ") {
            hasTodoPrefix = true
        }

        letterPrefix =
            letterPrefix
                .replacingOccurrences(of: "- [ ] ", with: "")
                .replacingOccurrences(of: "- [x] ", with: "")

        return (hasTodoPrefix, hasIncompletedTask, whitespacePrefix + letterPrefix)
    }

    private func hasPrefix(line: String, numbers: Bool) -> Bool {
        if line.starts(with: "- [ ] ") || line.starts(with: "- [x] ") {
            return false
        }

        var checkNumberDot = false

        for char in line {
            if checkNumberDot {
                if char == "." {
                    return numbers
                }
            }

            if char.isWhitespace {
                continue
            } else {
                if char.isNumber {
                    checkNumberDot = true
                    continue
                } else if char == "-" {
                    return !numbers
                } else {
                    return false
                }
            }
        }

        return false
    }

    // MARK: - WYSIWYG Toolbar Methods

    public func horizontalRule() {
        insertText("\n---\n")
    }
}
