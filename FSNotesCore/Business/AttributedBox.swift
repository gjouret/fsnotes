//
//  AttributedBox.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 8/30/18.
//  Copyright © 2018 Oleksandr Glushchenko. All rights reserved.
//

#if os(iOS)
    import UIKit
#else
    import Cocoa
#endif

class AttributedBox {
    public static func getChecked(clean: Bool = false) -> NSMutableAttributedString? {
        let checkboxText = getCleanChecked()
        if clean {
            return checkboxText
        }
        
        checkboxText.append(NSAttributedString(string: " "))

        return checkboxText
    }

    public static func getUnChecked(clean: Bool = false) -> NSMutableAttributedString? {
        let checkboxText = getCleanUnchecked()
        if clean {
            return checkboxText
        }
        
        checkboxText.append(NSAttributedString(string: " "))

        return checkboxText
    }

    public static func getCleanUnchecked() -> NSMutableAttributedString {
        let font = NotesTextProcessor.font
        let size = font.pointSize + 3
        let image = getImage(name: "checkbox_empty")
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: CGFloat(0), y: (font.capHeight - size) / 2, width: size, height: size)

        let checkboxText = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))

        checkboxText.addAttribute(.todo, value: 0, range: NSRange(0..<1))
        checkboxText.addAttribute(.font, value: font, range: NSRange(0..<1))
        // Ensure no stale syntax-hiding attributes (negative kern, clear color)
        // leak onto the checkbox from previous text at the insertion point.
        checkboxText.removeAttribute(.kern, range: NSRange(0..<1))
        #if os(macOS)
        checkboxText.addAttribute(.foregroundColor, value: NSColor.textColor, range: NSRange(0..<1))
        #endif

        if #available(OSX 10.13, iOS 10.0, *) {
        } else {
            let offset = (font.capHeight - size) / 2
            checkboxText.addAttribute(.baselineOffset, value: offset, range: NSRange(0..<1))
        }

        // Do NOT set .paragraphStyle here — phase5 is the single source of truth
        // for paragraph styles (headIndent, firstLineHeadIndent, spacing, etc.).

        return checkboxText
    }

    public static func getCleanChecked() -> NSMutableAttributedString {
        let font = NotesTextProcessor.font
        let size = font.pointSize + 3
        let attachment = NSTextAttachment()
        let image = getImage(name: "checkbox")
        attachment.image = image
        attachment.bounds = CGRect(x: CGFloat(0), y: (font.capHeight - size) / 2, width: size, height: size)

        let checkboxText = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))

        checkboxText.addAttribute(.todo, value: 1, range: NSRange(0..<1))
        checkboxText.addAttribute(.font, value: font, range: NSRange(0..<1))
        checkboxText.removeAttribute(.kern, range: NSRange(0..<1))
        #if os(macOS)
        checkboxText.addAttribute(.foregroundColor, value: NSColor.textColor, range: NSRange(0..<1))
        #endif

        if #available(OSX 10.13, iOS 10.0, *) {
        } else {
            let offset = (font.capHeight - size) / 2
            checkboxText.addAttribute(.baselineOffset, value: offset, range: NSRange(0..<1))
        }

        // Do NOT set .paragraphStyle here — phase5 is the single source of truth
        // for paragraph styles (headIndent, firstLineHeadIndent, spacing, etc.).

        return checkboxText
    }

    public static func getImage(name: String) -> Image {
        var name = name

        #if os(OSX)
            if name == "checkbox" {
                if #available(OSX 10.15, *) {
                    name = "checkbox_new"
                } else {
                    name = "checkbox_flipped"
                }
            }
            return NSImage(named: name)!
        #else
            return UIImage(named: name)!
        #endif
    }
}
