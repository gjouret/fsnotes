//
//  CustomTextStorage.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 10/12/18.
//  Copyright © 2018 Oleksandr Glushchenko. All rights reserved.
//

#if os(OSX)
import AppKit
#else
import UIKit
#endif

extension NSTextStorage {
#if os(OSX)
    public var highlightColor: NSColor {
        get {
            return NSColor(named: "highlight")!
        }
    }
#else
    public var highlightColor: UIColor {
        get {
            return UIColor.highlightColor
        }
    }
#endif

    public func getImageRange(url: URL) -> NSRange? {
        let affectedRange = NSRange(0..<length)
        var foundRange: NSRange?

        enumerateAttribute(.attachment, in: affectedRange) { (value, range, stop) in
            guard let meta = getMeta(at: range.location),
                  url.path == meta.url.path else { return }

            foundRange = range
            stop.pointee = true
        }

        return foundRange
    }

    public func updateParagraphStyle(range: NSRange? = nil) {
        let scanRange = range ?? NSRange(0..<length)
        
        guard scanRange.length != 0 else { return }

        beginEditing()
        let font = UserDefaultsManagement.noteFont
        let tabs = getTabStops()
        addTabStops(range: scanRange, tabs: tabs)
        let spaceWidth = " ".widthOfString(usingFont: font, tabs: tabs)

        let parRange = mutableString.paragraphRange(for: scanRange)

        enumerateAttribute(.attachment, in: parRange, options: .init()) { value, range, _ in
            guard attribute(.todo, at: range.location, effectiveRange: nil) != nil else { return }

            let currentParRange = mutableString.paragraphRange(for: range)

            var attachmentWidth: CGFloat = 0
            if let attachment = value as? NSTextAttachment {
                let attachmentBounds = attachment.bounds
                attachmentWidth = attachmentBounds.width
            }

            let parStyle = NSMutableParagraphStyle()
            parStyle.headIndent = spaceWidth + attachmentWidth
            parStyle.lineSpacing = CGFloat(UserDefaultsManagement.editorLineSpacing)
            addAttribute(.paragraphStyle, value: parStyle, range: currentParRange)
        }   
        endEditing()
    }

    /*
     * Implements https://github.com/glushchenko/fsnotes/issues/311
     */
    public func addTabStops(range: NSRange, tabs: [NSTextTab]) {
        // When WYSIWYG block model is active, Phase 5 handles paragraph styles.
        // Skip addTabStops to avoid overwriting block-aware spacing.
        if NotesTextProcessor.hideSyntax,
           let delegate = self.delegate as? TextStorageProcessor,
           !delegate.blocks.isEmpty {
            return
        }

        let font = UserDefaultsManagement.noteFont
        let lineSpacing = CGFloat(UserDefaultsManagement.editorLineSpacing)
        let paragraphRange = mutableString.paragraphRange(for: range)

        let markers = ["* ", "- ", "+ ", "> "]

        mutableString.enumerateSubstrings(in: paragraphRange, options: .byParagraphs) { value, parRange, _, _ in
            guard let value = value else { return }

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = lineSpacing
            paragraph.tabStops = tabs
            paragraph.alignment = .left

            var matchedPrefix: String?

            if value.count > 1 {
                let prefix = value.getSpacePrefix()

                if prefix.isEmpty {
                    for marker in markers {
                        if value.hasPrefix(marker) {
                            matchedPrefix = marker
                            break
                        }
                    }
                } else {
                    for marker in markers {
                        let fullMarker = prefix + marker
                        if value.hasPrefix(fullMarker) {
                            matchedPrefix = fullMarker
                            break
                        }
                    }
                }

                if matchedPrefix == nil {
                    matchedPrefix = self.getNumberListPrefix(paragraph: value)
                }

                if let prefix = matchedPrefix {
                    paragraph.headIndent = prefix.widthOfString(usingFont: font, tabs: tabs)
                }
            }

            // In WYSIWYG mode, add spacing to match MPreview CSS
            if NotesTextProcessor.hideSyntax {
                let isH1 = value.hasPrefix("# ") || value.hasPrefix("#\n")
                let isH2 = value.hasPrefix("## ") && !value.hasPrefix("### ")
                let isH3 = value.hasPrefix("### ") && !value.hasPrefix("#### ")

                // MPreview CSS: h1/h2 have padding-bottom: .3em, border-bottom, margin-bottom: 16px
                // The border is drawn by LayoutManager at maxY, so paragraphSpacing
                // must provide: .3em (text→border) + 16px (border→next paragraph)
                if isH1 || isH2 {
                    paragraph.paragraphSpacing = 20  // ~.3em + 16px
                } else if isH3 {
                    paragraph.paragraphSpacing = 12
                }

                // MPreview CSS: ul/ol have margin-bottom: 16px, li+li have margin-top: 0.25em
                // Detect list items (bullets, numbered, todos) but NOT blockquotes
                let isListItem = matchedPrefix != nil && matchedPrefix != "> "
                    && !(matchedPrefix?.hasPrefix("> ") ?? false)
                if isListItem {
                    // Check if previous/next paragraphs are also list items
                    let prevParEnd = parRange.location
                    let nextParStart = NSMaxRange(parRange)
                    let fullString = self.mutableString as String

                    var prevIsListItem = false
                    if prevParEnd > 0 {
                        let prevRange = (fullString as NSString).paragraphRange(for: NSRange(location: prevParEnd - 1, length: 0))
                        let prevPar = (fullString as NSString).substring(with: prevRange)
                        prevIsListItem = markers.contains(where: { prevPar.hasPrefix($0) || prevPar.contains(where: { $0.isWhitespace }) && markers.contains(where: { prevPar.trimmingCharacters(in: .whitespaces).hasPrefix($0) }) })
                            || self.getNumberListPrefix(paragraph: prevPar) != nil
                    }

                    var nextIsListItem = false
                    if nextParStart < fullString.count {
                        let nextRange = (fullString as NSString).paragraphRange(for: NSRange(location: nextParStart, length: 0))
                        let nextPar = (fullString as NSString).substring(with: nextRange)
                        nextIsListItem = markers.contains(where: { nextPar.hasPrefix($0) || nextPar.trimmingCharacters(in: .whitespaces).hasPrefix($0) })
                            || self.getNumberListPrefix(paragraph: nextPar) != nil
                    }

                    // First item in list: add space before (like margin-top on <ul>)
                    paragraph.paragraphSpacingBefore = prevIsListItem ? 4 : 12

                    // Last item in list: add space after (like margin-bottom on <ul>)
                    paragraph.paragraphSpacing = nextIsListItem ? 4 : 12
                }
            }

            self.addAttribute(.paragraphStyle, value: paragraph, range: parRange)
        }
    }

    public func getTabStops() -> [NSTextTab] {
        var tabs = [NSTextTab]()
        let tabInterval = 40

        for index in 1...25 {
            let tab = NSTextTab(textAlignment: .left, location: CGFloat(tabInterval * index), options: [:])
            tabs.append(tab)
        }

        return tabs
    }

    private static let numberListRegex = try? NSRegularExpression(
        pattern: #"^(\s*)(\d+)(\.)(\s+)"#,
        options: []
    )

    public func getNumberListPrefix(paragraph: String) -> String? {
        guard !paragraph.isEmpty else { return nil }

        let nsString = paragraph as NSString
        let range = NSRange(location: 0, length: min(nsString.length, 20))

        if let match = Self.numberListRegex?.firstMatch(in: paragraph, options: [], range: range) {
            return nsString.substring(with: match.range)
        }

        return nil
    }

    public func updateCheckboxList() {
        let fullRange = NSRange(location: 0, length: self.length)

        enumerateAttribute(.todo, in: fullRange, options: []) { value, range, _ in
            if let value = value as? Int {
                let attribute = self.attribute(.attachment, at: range.location, longestEffectiveRange: nil, in: fullRange)

                if let attachment = attribute as? NSTextAttachment {
                    let checkboxName = value == 0 ? "checkbox_empty" : "checkbox"

                    attachment.image = AttributedBox.getImage(name: checkboxName)

                    for layoutManager in layoutManagers {
                        layoutManager.invalidateDisplay(forCharacterRange: range)
                    }
                }
            }
        }
    }

    public func highlightKeyword(search: String) {
        var search = search
        guard search.count > 1, UserDefaultsManagement.searchHighlight else { return }
        
        if search.hasPrefix("\"") && search.hasSuffix("\"") {
            let clean = String(search.dropFirst().dropLast())
            if clean.count > 0 {
                search = clean
            }
        }
        
        let searchTerm = NSRegularExpression.escapedPattern(for: search)
        let pattern = "(\(searchTerm))"
        let range = NSRange(location: 0, length: length)
        
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let matches = regex.matches(in: self.string, options: [], range: range)
            
            self.beginEditing()
            for match in matches {
                let subRange = match.range
                guard subRange.location < self.length else { continue }
                
                if let currentBackgroundColor = self.attribute(.backgroundColor, at: subRange.location, effectiveRange: nil) {
                    self.addAttribute(.highlight, value: currentBackgroundColor, range: subRange)
                } else {
                    self.addAttribute(.highlight, value: NSNull(), range: subRange)
                }
                self.addAttribute(.backgroundColor, value: self.highlightColor, range: subRange)
            }
            self.endEditing()
            
        } catch {
            print(error)
        }
    }

    public func removeHighlight() {
        let range = NSRange(location: 0, length: length)

        self.beginEditing()
        self.enumerateAttribute(
            .highlight,
            in: range,
            options: []
        ) { value, subRange, _ in
            guard value != nil else { return }

            #if os(macOS)
            if let originalColor = value as? NSColor {
                self.addAttribute(.backgroundColor, value: originalColor, range: subRange)
            } else {
                self.removeAttribute(.backgroundColor, range: subRange)
            }
            #else
            if let originalColor = value as? UIColor {
                self.addAttribute(.backgroundColor, value: originalColor, range: subRange)
            } else {
                self.removeAttribute(.backgroundColor, range: subRange)
            }
            #endif

            self.removeAttribute(.highlight, range: subRange)
        }
        self.endEditing()
    }
}
