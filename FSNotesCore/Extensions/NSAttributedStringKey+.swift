//
//  NSAttributedStringKey+.swift
//  FSNotes
//
//  Created by Oleksandr Glushchenko on 10/15/18.
//  Copyright © 2018 Oleksandr Glushchenko. All rights reserved.
//

import Foundation

public enum RenderedBlockType: String {
    case mermaid, math, table, pdf, image, file
}

public extension NSAttributedString.Key {
    static let attachmentSave = NSAttributedString.Key(rawValue: "es.fsnot.attachment.save")
    static let attachmentUrl = NSAttributedString.Key(rawValue: "es.fsnot.attachment.url")
    static let attachmentPath = NSAttributedString.Key(rawValue: "es.fsnot.attachment.path")
    static let attachmentTitle = NSAttributedString.Key(rawValue: "es.fsnot.attachment.title")
    static let tag = NSAttributedString.Key(rawValue: "es.fsnot.tag")
    static let yamlBlock = NSAttributedString.Key(rawValue: "es.fsnot.yaml")
    static let highlight = NSAttributedString.Key(rawValue: "es.fsnot.highlight")
    static let horizontalRule = NSAttributedString.Key(rawValue: "es.fsnot.hr")
    static let blockquote = NSAttributedString.Key(rawValue: "es.fsnot.blockquote")
    static let renderedBlockSource = NSAttributedString.Key(rawValue: "es.fsnot.rendered.source")
    static let renderedBlockType = NSAttributedString.Key(rawValue: "es.fsnot.rendered.type")
    static let renderedBlockRange = NSAttributedString.Key(rawValue: "es.fsnot.rendered.range")
    static let renderedBlockOriginalMarkdown = NSAttributedString.Key(rawValue: "es.fsnot.rendered.original")
    static let bulletMarker = NSAttributedString.Key(rawValue: "es.fsnot.bullet.marker")
    static let checkboxMarker = NSAttributedString.Key(rawValue: "es.fsnot.checkbox.marker")
    static let orderedMarker = NSAttributedString.Key(rawValue: "es.fsnot.ordered.marker")
    static let listDepth = NSAttributedString.Key(rawValue: "es.fsnot.list.depth")
    static let codeFence = NSAttributedString.Key(rawValue: "es.fsnot.code.fence")
    static let kbdTag = NSAttributedString.Key(rawValue: "es.fsnot.kbd")
    static let foldedContent = NSAttributedString.Key(rawValue: "es.fsnot.folded.content")
    static let inlineMathSource = NSAttributedString.Key(rawValue: "es.fsnot.inline.math")
    static let displayMathSource = NSAttributedString.Key(rawValue: "es.fsnot.display.math")
}
