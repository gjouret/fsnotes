//
//  FormattingToolbar.swift
//  FSNotes
//
//  Created on 2026-03-23.
//

import Cocoa

class FormattingToolbar: NSView {

    private var stackView: NSStackView!
    private var buttons: [String: NSButton] = [:]
    private weak var currentEditor: EditTextView?

    /// Memoization state for `updateButtonStates` (Perf plan #1). Arrow
    /// keys fire `textViewDidChangeSelection` on every cursor move; the
    /// unmemoized path resolves heading state and reads multiple storage
    /// attributes per call. Caching by (projection identity,
    /// cursor block index, paragraph range) lets us skip the work
    /// entirely while the cursor stays in the same block.
    private weak var cachedProjectionAttributed: NSAttributedString?
    private var cachedBlockIndex: Int = -1
    private var cachedParagraphRange: NSRange = .init(location: NSNotFound, length: 0)
    private var cachedTypingAttributesSnapshot: [NSAttributedString.Key: NSObject] = [:]

    static let toolbarHeight: CGFloat = 32

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupToolbar()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupToolbar()
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    private func setupToolbar() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1)
        ])

        stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 2
        stackView.alignment = .centerY
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        // Navigation buttons (target ViewController directly)
        addButton(id: "back", symbol: "chevron.left", tooltip: "Back", action: #selector(ViewController.navigateBack(_:)))
        addButton(id: "forward", symbol: "chevron.right", tooltip: "Forward", action: #selector(ViewController.navigateForward(_:)))
        // Start disabled
        buttons["back"]?.isEnabled = false
        buttons["forward"]?.isEnabled = false

        addSeparator()

        // Formatting buttons route through this toolbar and then call the
        // active editor's existing action methods. Keeping target=nil here
        // is fragile: a toolbar click can leave AppKit with no editor target
        // for some selectors even though the editor selection is still valid.

        // Style group
        addButton(id: "bold", symbol: "bold", tooltip: "Bold (Cmd+B)", target: self, action: #selector(pressBoldToolbarButton(_:)), isToggle: true)
        addButton(id: "italic", symbol: "italic", tooltip: "Italic (Cmd+I)", target: self, action: #selector(pressItalicToolbarButton(_:)), isToggle: true)
        addButton(id: "underline", symbol: "underline", tooltip: "Underline (Cmd+U)", target: self, action: #selector(pressUnderlineToolbarButton(_:)), isToggle: true)
        addButton(id: "strikethrough", symbol: "strikethrough", tooltip: "Strikethrough", target: self, action: #selector(pressStrikethroughToolbarButton(_:)), isToggle: true)
        addButton(id: "highlight", symbol: "highlighter", tooltip: "Highlight", target: self, action: #selector(pressHighlightToolbarButton(_:)), isToggle: true)

        addSeparator()

        // Heading group
        addButton(id: "h1", title: "H1", tooltip: "Heading 1", target: self, action: #selector(pressHeading1ToolbarButton(_:)), isToggle: true)
        addButton(id: "h2", title: "H2", tooltip: "Heading 2", target: self, action: #selector(pressHeading2ToolbarButton(_:)), isToggle: true)
        addButton(id: "h3", title: "H3", tooltip: "Heading 3", target: self, action: #selector(pressHeading3ToolbarButton(_:)), isToggle: true)

        addSeparator()

        // Block group
        addButton(id: "quote", symbol: "text.quote", tooltip: "Quote", target: self, action: #selector(pressQuoteToolbarButton(_:)), isToggle: true)
        addButton(id: "bulletList", symbol: "list.bullet", tooltip: "Bullet List", target: self, action: #selector(pressBulletListToolbarButton(_:)), isToggle: true)
        addButton(id: "numberedList", symbol: "list.number", tooltip: "Numbered List", target: self, action: #selector(pressNumberedListToolbarButton(_:)), isToggle: true)
        addButton(id: "checkbox", symbol: "checkmark.square", tooltip: "Checkbox", target: self, action: #selector(pressCheckboxToolbarButton(_:)), isToggle: true)

        addSeparator()

        // Insert group
        addButton(id: "link", symbol: "link", tooltip: "Insert Link (Cmd+K)", action: #selector(EditTextView.linkMenu(_:)))
        addButton(id: "wikilink", symbol: "doc.text", tooltip: "Wiki-Link to Note", action: #selector(EditTextView.wikiLinks(_:)))
        addButton(id: "image", symbol: "paperclip", tooltip: "Insert Image/File", action: #selector(EditTextView.insertFileOrImage(_:)))
        addButton(id: "table", symbol: "tablecells", tooltip: "Insert Table", action: #selector(EditTextView.insertTableMenu(_:)))
        addButton(id: "codeBlock", symbol: "chevron.left.forwardslash.chevron.right", tooltip: "Code Block", action: #selector(EditTextView.insertCodeBlock(_:)))
        addButton(id: "horizontalRule", symbol: "minus", tooltip: "Horizontal Rule", action: #selector(EditTextView.horizontalRuleMenu(_:)))

        addSeparator()

        // AI Chat
        addButton(id: "aiChat", symbol: "bubble.left.and.text.bubble.right", tooltip: "AI Assistant", action: #selector(ViewController.toggleAIChat(_:)))
    }

    // MARK: - Button Creation

    private func addButton(id: String, symbol: String? = nil, title: String? = nil, tooltip: String, target: AnyObject? = nil, action: Selector, isToggle: Bool = false) {
        let button = NSButton()
        button.bezelStyle = .accessoryBarAction
        button.isBordered = true
        button.setButtonType(isToggle ? .pushOnPushOff : .momentaryPushIn)

        if let symbol = symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            button.imagePosition = .imageOnly
        } else if let title = title {
            button.title = title
            button.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        }

        button.toolTip = tooltip
        button.target = target // nil routes through the first responder chain
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.refusesFirstResponder = true // keep focus on EditTextView

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 24)
        ])

        stackView.addArrangedSubview(button)
        buttons[id] = button
    }

    private func addSeparator() {
        // Left spacer
        let leftSpacer = NSView()
        leftSpacer.translatesAutoresizingMaskIntoConstraints = false
        leftSpacer.widthAnchor.constraint(equalToConstant: 4).isActive = true
        stackView.addArrangedSubview(leftSpacer)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 18)
        ])
        stackView.addArrangedSubview(separator)

        // Right spacer
        let rightSpacer = NSView()
        rightSpacer.translatesAutoresizingMaskIntoConstraints = false
        rightSpacer.widthAnchor.constraint(equalToConstant: 4).isActive = true
        stackView.addArrangedSubview(rightSpacer)
    }

    // MARK: - Editor Action Routing

    private func editorForToolbarAction() -> EditTextView? {
        if let editor = currentEditor, editor.window === window {
            return editor
        }

        var responder = window?.firstResponder
        while let current = responder {
            if let editor = current as? EditTextView {
                return editor
            }
            responder = current.nextResponder
        }

        return nil
    }

    @objc private func pressBoldToolbarButton(_ sender: Any) {
        editorForToolbarAction()?.boldMenu(sender)
    }

    @objc private func pressItalicToolbarButton(_ sender: Any) {
        editorForToolbarAction()?.italicMenu(sender)
    }

    @objc private func pressUnderlineToolbarButton(_ sender: Any) {
        editorForToolbarAction()?.underlineMenu(sender)
    }

    @objc private func pressStrikethroughToolbarButton(_ sender: Any) {
        editorForToolbarAction()?.strikeMenu(sender)
    }

    @objc private func pressHighlightToolbarButton(_ sender: Any) {
        editorForToolbarAction()?.highlightMenu(sender)
    }

    @objc private func pressHeading1ToolbarButton(_ sender: Any) {
        editorForToolbarAction()?.headerMenu1(sender)
    }

    @objc private func pressHeading2ToolbarButton(_ sender: Any) {
        editorForToolbarAction()?.headerMenu2(sender)
    }

    @objc private func pressHeading3ToolbarButton(_ sender: Any) {
        editorForToolbarAction()?.headerMenu3(sender)
    }

    @objc private func pressQuoteToolbarButton(_ sender: Any) {
        editorForToolbarAction()?.quoteMenu(sender)
    }

    @objc private func pressBulletListToolbarButton(_ sender: Any) {
        editorForToolbarAction()?.bulletListMenu(sender)
    }

    @objc private func pressNumberedListToolbarButton(_ sender: Any) {
        editorForToolbarAction()?.numberedListMenu(sender)
    }

    @objc private func pressCheckboxToolbarButton(_ sender: Any) {
        editorForToolbarAction()?.todo(sender)
    }

    // MARK: - Button State Updates

    /// Capture only the inline-format-relevant bits of typingAttributes
    /// (font, strikethrough, underline, background color). Used as the
    /// memoization key for `updateButtonStates` so cursor moves within
    /// the same block don't redo the same work.
    private func toolbarTypingAttributesSnapshot(_ editor: EditTextView) -> [NSAttributedString.Key: NSObject] {
        var snap: [NSAttributedString.Key: NSObject] = [:]
        if let font = editor.typingAttributes[.font] as? NSFont {
            snap[.font] = font
        }
        if let s = editor.typingAttributes[.strikethroughStyle] as? NSNumber {
            snap[.strikethroughStyle] = s
        }
        if let u = editor.typingAttributes[.underlineStyle] as? NSNumber {
            snap[.underlineStyle] = u
        }
        if let bg = editor.typingAttributes[.backgroundColor] as? NSColor {
            snap[.backgroundColor] = bg
        }
        return snap
    }

    func updateButtonStates(for editor: EditTextView) {
        currentEditor = editor

        guard let storage = editor.textStorage, storage.length > 0 else {
            resetAllButtons()
            return
        }

        let range = editor.selectedRange()
        // Cursor at end of text — no character to check, reset all buttons.
        // Using storage.length - 1 would clamp back onto the previous line's newline,
        // falsely detecting heading/bold/etc. from the line above.
        guard range.location < storage.length else {
            resetAllButtons()
            return
        }
        let location = range.location

        // Fast-path memoization (Perf plan #1): when the cursor stayed
        // inside the same block of the same projection AND typing
        // attributes haven't changed, the toolbar state is identical
        // to the last call. Skip everything.
        let paragraphRange = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        let projectionAttr = editor.documentProjection?.rendered.attributed
        let currentCursorBlock: Int = {
            if let proj = editor.documentProjection,
               let (bIdx, _) = proj.blockContaining(storageIndex: location) {
                return bIdx
            }
            return -1
        }()
        let typingSnapshot = toolbarTypingAttributesSnapshot(editor)
        if projectionAttr != nil,
           cachedProjectionAttributed === projectionAttr,
           cachedBlockIndex == currentCursorBlock,
           NSEqualRanges(cachedParagraphRange, paragraphRange),
           cachedTypingAttributesSnapshot == typingSnapshot {
            return
        }
        cachedProjectionAttributed = projectionAttr
        cachedBlockIndex = currentCursorBlock
        cachedParagraphRange = paragraphRange
        cachedTypingAttributesSnapshot = typingSnapshot

        // Determine heading level. Prefer the block-model lookup (O(log N)
        // via binary search in `blockContaining`) over the source-mode
        // walk. Sub-slice 7.B.2.a routes the source-mode arm through
        // `headingLevel(forParagraphRange:)` so this site no longer
        // touches the source-mode block array directly.
        var headingLevel = 0
        if let proj = editor.documentProjection,
           currentCursorBlock >= 0,
           currentCursorBlock < proj.document.blocks.count {
            if case .heading(let level, _) = proj.document.blocks[currentCursorBlock] {
                headingLevel = level
            }
        } else if let processor = editor.textStorageProcessor {
            headingLevel = processor.headingLevel(forParagraphRange: paragraphRange)
        }

        setButtonState("h1", active: headingLevel == 1)
        setButtonState("h2", active: headingLevel == 2)
        setButtonState("h3", active: headingLevel >= 3)

        // Read formatting attributes. When cursor is a point (no selection), use
        // typingAttributes — these reflect the ACTUAL formatting for the next character,
        // not the storage attributes which may be stale from the previous line (e.g.,
        // heading font on a newline character after pressing Return).
        let attrs: [NSAttributedString.Key: Any]
        if range.length == 0 {
            attrs = editor.typingAttributes
        } else {
            var effectiveAttrs: [NSAttributedString.Key: Any] = [:]
            if let font = storage.attribute(.font, at: location, effectiveRange: nil) {
                effectiveAttrs[.font] = font
            }
            if let strike = storage.attribute(.strikethroughStyle, at: location, effectiveRange: nil) {
                effectiveAttrs[.strikethroughStyle] = strike
            }
            if let underline = storage.attribute(.underlineStyle, at: location, effectiveRange: nil) {
                effectiveAttrs[.underlineStyle] = underline
            }
            if let bg = storage.attribute(.backgroundColor, at: location, effectiveRange: nil) {
                effectiveAttrs[.backgroundColor] = bg
            }
            attrs = effectiveAttrs
        }

        // Inline formatting — suppress bold/italic when inside a heading
        if let font = attrs[.font] as? NSFont {
            let traits = font.fontDescriptor.symbolicTraits
            setButtonState("bold", active: headingLevel == 0 && traits.contains(.bold))
            setButtonState("italic", active: headingLevel == 0 && traits.contains(.italic))
        } else {
            setButtonState("bold", active: false)
            setButtonState("italic", active: false)
        }

        let hasStrike = attrs[.strikethroughStyle] != nil
        setButtonState("strikethrough", active: hasStrike)

        let hasUnderline = attrs[.underlineStyle] != nil
        setButtonState("underline", active: hasUnderline)

        // Check for highlight (<mark> tag — sets backgroundColor with yellow-ish RGB)
        if let bg = attrs[.backgroundColor] as? NSColor,
           let rgb = bg.usingColorSpace(.deviceRGB) {
            let isHighlight = rgb.redComponent > 0.8 && rgb.greenComponent > 0.8 && rgb.blueComponent < 0.3
            setButtonState("highlight", active: isHighlight)
        } else {
            setButtonState("highlight", active: false)
        }

        // Check block type from projection when in block model mode (WYSIWYG)
        // This is more reliable than checking raw text prefixes which don't exist
        // in the rendered output.
        var isQuote = false
        var isBulletList = false
        var isNumberedList = false
        var isCheckbox = false
        
        if let proj = editor.documentProjection,
           currentCursorBlock >= 0,
           currentCursorBlock < proj.document.blocks.count {
            switch proj.document.blocks[currentCursorBlock] {
            case .blockquote:
                isQuote = true
            case .list(let items, _):
                // Determine list type from the first item's marker
                if let firstItem = items.first {
                    let marker = firstItem.marker
                    if marker == "-" || marker == "*" || marker == "+" {
                        if firstItem.checkbox != nil {
                            isCheckbox = true
                        } else {
                            isBulletList = true
                        }
                    } else if marker.range(of: #"^\d+[.\)]"#, options: .regularExpression) != nil {
                        isNumberedList = true
                    }
                }
            default:
                break
            }
        }
        
        // Fallback to text-based detection for source mode
        let paragraphText = (storage.string as NSString).substring(with: paragraphRange).trimmingCharacters(in: .whitespaces)
        
        setButtonState("quote", active: isQuote || paragraphText.hasPrefix(">"))
        setButtonState("bulletList", active: isBulletList || paragraphText.hasPrefix("- ") || paragraphText.hasPrefix("* ") || paragraphText.hasPrefix("+ "))
        setButtonState("numberedList", active: isNumberedList || paragraphText.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil)
        setButtonState("checkbox", active: isCheckbox || paragraphText.hasPrefix("- [ ]") || paragraphText.hasPrefix("- [x]"))
    }

    private func setButtonState(_ id: String, active: Bool) {
        buttons[id]?.state = active ? .on : .off
    }

    private func resetAllButtons() {
        buttons.values.forEach { $0.state = .off }
    }

    func updateNavigationButtons(canGoBack: Bool, canGoForward: Bool) {
        buttons["back"]?.isEnabled = canGoBack
        buttons["forward"]?.isEnabled = canGoForward
    }
}
