//
//  NotesTextStorage.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 12/26/17.
//  Copyright © 2017 Oleksandr Glushchenko. All rights reserved.
//

#if os(OSX)
    import Cocoa
    import MASShortcut
#else
    import UIKit
#endif

public class NotesTextProcessor {
#if os(OSX)
    typealias Color = NSColor
    typealias Image = NSImage
    typealias Font = NSFont

    /// Link color used by the editor renderer.
    private static let wysiwygLinkColor = NSColor(red: 0.251, green: 0.471, blue: 0.753, alpha: 1.0)

    public static var fontColor: NSColor {
        get {
            return NSColor(named: "mainText")!
        }
    }
#else
    typealias Color = UIColor
    typealias Image = UIImage
    typealias Font = UIFont

    public static var fontColor: UIColor {
        get {
            return UIColor { (traits) -> UIColor in
                return traits.userInterfaceStyle == .dark ?
                    UIColor.white :
                    UIColor.black
            }
        }
    }
#endif
    // MARK: Syntax highlight customisation
    
    /**
     Color used to highlight markdown syntax. Default value is light grey.
     */
    public static var syntaxColor = Color.lightGray
    
    public static var yamlOpenerColor = Color.systemRed
    
    public static var codeBackground: PlatformColor {
        get {
            let isDark = UserDataService.instance.isDark
            let editorTheme = UserDefaultsManagement.codeTheme.makeStyle(isDark: isDark)
            
            return editorTheme.backgroundColor
        }
    }
    
#if os(OSX)
    public static var font: NSFont {
        get {
            return UserDefaultsManagement.noteFont
        }
    }

    public static var codeSpanBackground: NSColor {
        get {
            return NSColor(named: "code") ?? NSColor(red:0.97, green:0.97, blue:0.97, alpha:1.0)
        }
    }

    public static var quoteColor: NSColor {
        get {
            return NSColor(named: "quoteColor")!
        }
    }
#else
    public static var font: UIFont {
        get {
            return UserDefaultsManagement.noteFont
        }
    }

    public static var codeSpanBackground: UIColor {
        get {
            return UIColor.codeBackground
        }
    }
    
    public static var quoteColor: UIColor {
        get {
            return UIColor.darkGray
        }
    }
#endif
    
    static var codeFont = UserDefaultsManagement.codeFont
    
    /**
     If the markdown syntax should be hidden or visible
     */
    public static var hideSyntax = false
    
    private var note: Note?
    private var storage: NSTextStorage?
    private var range: NSRange?
    private var width: CGFloat?
    
    public static var hl: SwiftHighlighter? = nil

    /// Serializes lazy init of `hl`. Required because
    /// `preLoadProjectsData` fans out `Note.cache()` across
    /// `DispatchQueue.concurrentPerform`, and two workers racing into
    /// `getHighlighter()` would both construct a SwiftHighlighter. The
    /// constructor populates a Dictionary (language registration) that
    /// isn't thread-safe — two concurrent inits corrupt the dictionary
    /// and abort with `-[NSIndexPath count]: unrecognized selector`.
    private static let hlLock = NSLock()

    init(note: Note? = nil, storage: NSTextStorage? = nil, range: NSRange? = nil) {
        self.note = note
        self.storage = storage
        self.range = range
    }

    public static func getHighlighter() -> SwiftHighlighter {
        // Fast path: already constructed. Reads of an Optional pointer
        // are atomic on every platform we run on, so this doesn't need
        // the lock in the common case.
        if let instance = self.hl {
            return instance
        }

        hlLock.lock()
        defer { hlLock.unlock() }

        // Double-checked: another thread may have constructed between
        // the first read and acquiring the lock.
        if let instance = self.hl {
            return instance
        }

        let isDark = UserDataService.instance.isDark
        let style = UserDefaultsManagement.codeTheme.makeStyle(isDark: isDark)
        let highlighter = SwiftHighlighter(options: .init(style: style))
        self.hl = highlighter

        return highlighter
    }

    public static func resetCaches() {
        hlLock.lock()
        defer { hlLock.unlock() }
        NotesTextProcessor.hl = nil
        NotesTextProcessor.codeFont = UserDefaultsManagement.codeFont
    }

    public static func getSpanCodeBlockRange(content: NSMutableAttributedString, range: NSRange) -> NSRange? {
        var codeSpan: NSRange?
        let paragraphRange = content.mutableString.paragraphRange(for: range)
        let paragraph = content.attributedSubstring(from: paragraphRange).string

        if paragraph.contains("`") {
            NotesTextProcessor.codeSpanRegex.matches(content.string, range: paragraphRange) { (result) -> Void in
                if let spanRange = result?.range, spanRange.intersection(range) != nil {
                    codeSpan = spanRange
                }
            }
        }
        
        return codeSpan
    }

    /**
     Coverts App links:`[[Link Title]]` to Markdown: `[Link](fsnotes://find/link%20title)`
     
     - parameter content:      A string containing CommonMark Markdown
     
     - returns: Content string with converted links
     */

    public static func convertAppLinks(in content: NSMutableAttributedString, codeBlockRanges: [NSRange]?) -> NSMutableAttributedString {
        let attributedString = content.mutableCopy() as! NSMutableAttributedString
        let range = NSRange(0..<content.string.utf16.count)
        let tagQuery = "fsnotes://find?id="

        NotesTextProcessor.appUrlRegex.matches(content.string, range: range, completion: { (result) -> (Void) in
            guard let innerRange = result?.range else { return }

            var substring = attributedString.mutableString.substring(with: innerRange)
            substring = substring
                .replacingOccurrences(of: "[[", with: "")
                .replacingOccurrences(of: "]]", with: "")
                .trim()

            guard let tag = substring.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return }

            attributedString.addAttribute(.link, value: "\(tagQuery)\(tag)", range: innerRange)
        })

        attributedString.enumerateAttribute(.link, in: range) { (value, range, _) in
            if let value = value as? String, value.starts(with: tagQuery) {
                if let tag = value
                    .replacingOccurrences(of: tagQuery, with: "")
                    .removingPercentEncoding
                {

                    if NotesTextProcessor.getSpanCodeBlockRange(content: attributedString, range: range) != nil {
                        return
                    }

                    if let codeRanges = codeBlockRanges {
                        for codeRange in codeRanges {
                            if NSIntersectionRange(codeRange, range).length > 0 {
                                return
                            }
                        }
                    }

                    let link = "[\(tag)](\(value))"
                    attributedString.replaceCharacters(in: range, with: link)
                }
            }
        }
        
        return attributedString
    }

    public static func convertAppTags(in content: NSMutableAttributedString, codeBlockRanges: [NSRange]?) -> NSMutableAttributedString {
        let attributedString = content.mutableCopy() as! NSMutableAttributedString
        guard UserDefaultsManagement.inlineTags else { return attributedString}

        let range = NSRange(0..<content.string.utf16.count)
        let tagQuery = "fsnotes://open/?tag="

        FSParser.tagsInlineRegex.matches(content.string, range: range) { (result) -> Void in
            guard var range = result?.range(at: 1) else { return }

            var substring = attributedString.mutableString.substring(with: range)
            guard !substring.isNumber else { return }

            range = NSRange(location: range.location - 1, length: range.length + 1)
            substring = attributedString.mutableString.substring(with: range)
                .replacingOccurrences(of: "#", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .trim()

            guard let tag = substring.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return }

            attributedString.addAttribute(.link, value: "\(tagQuery)\(tag)", range: range)
        }

        attributedString.enumerateAttribute(.link, in: range) { (value, range, _) in
            if let value = value as? String, value.starts(with: tagQuery) {
                if let tag = value
                    .replacingOccurrences(of: tagQuery, with: "")
                    .removingPercentEncoding
                {

                    if NotesTextProcessor.getSpanCodeBlockRange(content: attributedString, range: range) != nil {
                        return
                    }

                    if let codeRanges = codeBlockRanges {
                        for codeRange in codeRanges {
                            if NSIntersectionRange(codeRange, range).length > 0 {
                                return
                            }
                        }
                    }

                    let link = "[#\(tag)](\(value))"
                    attributedString.replaceCharacters(in: range, with: link)
                }
            }
        }

        return attributedString
    }

    public static func resetFont(attributedString: NSMutableAttributedString, paragraphRange: NSRange) {
        attributedString.addAttribute(.font, value: font, range: paragraphRange)
        attributedString.removeAttribute(.kern, range: paragraphRange)
        attributedString.fixAttributes(in: paragraphRange)
    }
    
    fileprivate static let codeSpanPattern = [
        "(?<![\\\\`])   # Character before opening ` can't be a backslash or backtick",
        "(`+)           # $1 = Opening run of `",
        "(?!`)          # and no more backticks -- match the full run",
        "(.+?)          # $2 = The code block",
        "(?<!`)",
        "\\1",
        "(?!`)"
        ].joined(separator: "\n")
    
    public static let codeSpanRegex = MarklightRegex(pattern: codeSpanPattern, options: [.allowCommentsAndWhitespace, .dotMatchesLineSeparators])

    // MARK: App url
    
    fileprivate static let appUrlPattern = "(\\[\\[)(.+?[\\[\\]]*)(\\]\\])"

    public static let appUrlRegex = MarklightRegex(pattern: appUrlPattern, options: [.anchorsMatchLines])

    public static func getHeaderFont(level: Int, baseFont: PlatformFont, baseFontSize: CGFloat) -> PlatformFont {
        let headerSize: CGFloat
        
        switch level {
        case 1: headerSize = baseFontSize * 2.0    // #
        case 2: headerSize = baseFontSize * 1.7    // ##
        case 3: headerSize = baseFontSize * 1.4    // ###
        case 4: headerSize = baseFontSize * 1.2    // ####
        case 5: headerSize = baseFontSize * 1.1    // #####
        case 6: headerSize = baseFontSize * 1.05   // ######
        default: headerSize = baseFontSize
        }
        
        let boldTraits: FontTraits = [.bold]
        var fontDescriptor = baseFont.fontDescriptor
            .withSymbolicTraits(boldTraits)
        
        #if os(OSX)
            fontDescriptor = fontDescriptor.withSize(headerSize)
        
            return PlatformFont(descriptor: fontDescriptor, size: headerSize) ?? baseFont
        #else
            fontDescriptor = fontDescriptor?.withSize(headerSize)
        
            guard let fontDescriptor = fontDescriptor else { return baseFont }
        
            return PlatformFont(descriptor: fontDescriptor, size: headerSize)
        #endif
    }
}

public struct MarklightRegex {
    public let regularExpression: NSRegularExpression!
    
    public init(pattern: String, options: NSRegularExpression.Options = NSRegularExpression.Options(rawValue: 0)) {
        var error: NSError?
        let re: NSRegularExpression?
        do {
            re = try NSRegularExpression(pattern: pattern,
                                         options: options)
        } catch let error1 as NSError {
            error = error1
            re = nil
        }
        
        // If re is nil, it means NSRegularExpression didn't like
        // the pattern we gave it.  All regex patterns used by Markdown
        // should be valid, so this probably means that a pattern
        // valid for .NET Regex is not valid for NSRegularExpression.
        if re == nil {
            if let error = error {
                print("Regular expression error: \(error.userInfo)")
            }
            assert(re != nil)
        }
        
        self.regularExpression = re
    }
    
    public func matches(_ input: String, range: NSRange,
                        completion: @escaping (_ result: NSTextCheckingResult?) -> Void) {
        let s = input as NSString
        //NSRegularExpression.
        let options = NSRegularExpression.MatchingOptions(rawValue: 0)
        regularExpression.enumerateMatches(in: s as String,
                                           options: options,
                                           range: range,
                                           using: { (result, flags, stop) -> Void in

                                            completion(result)
        })
    }
}
