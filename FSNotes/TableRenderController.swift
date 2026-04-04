//
//  TableRenderController.swift
//  FSNotes
//
//  Manages inline table rendering, insertion, cell formatting, and data sync.
//  Extracted from EditTextView to reduce god object size.
//

import Cocoa

class TableRenderController {

    weak var textView: EditTextView?

    init(textView: EditTextView) {
        self.textView = textView
    }

    // MARK: - Table Data Sync

    /// Materialize live InlineTableView cell data back into attachment attributes.
    /// If there are no live inline table views, saving should remain a pure read.
    func prepareRenderedTablesForSave() {
        guard let textView = textView, let storage = textView.textStorage else { return }
        guard textView.subviews.contains(where: { $0 is InlineTableView }) else { return }

        // Clean up "spread" rendered-block attributes from non-attachment chars.
        let fullRange = NSRange(location: 0, length: storage.length)
        let string = storage.string as NSString
        var cleanRanges: [NSRange] = []
        storage.enumerateAttribute(.renderedBlockOriginalMarkdown, in: fullRange, options: []) { value, range, _ in
            guard value != nil else { return }
            for i in range.location..<NSMaxRange(range) {
                if i < string.length && string.character(at: i) != 0xFFFC {
                    cleanRanges.append(NSRange(location: i, length: 1))
                }
            }
        }
        for r in cleanRanges.reversed() {
            storage.removeAttribute(.renderedBlockOriginalMarkdown, range: r)
            storage.removeAttribute(.renderedBlockSource, range: r)
            storage.removeAttribute(.renderedBlockType, range: r)
        }

        // Update each table attachment with current cell data.
        storage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, stop in
            guard let att = value as? NSTextAttachment,
                  let cell = att.attachmentCell as? InlineTableAttachmentCell else { return }
            let tableView = cell.inlineTableView
            tableView.collectCellData()
            let markdown = tableView.generateMarkdown()
            storage.addAttribute(.renderedBlockOriginalMarkdown, value: markdown, range: range)
            storage.addAttribute(.renderedBlockSource, value: markdown, range: range)
        }
    }

    // MARK: - Table Rendering

    /// Render markdown tables as InlineTableView widgets.
    func renderTables() {
        guard let textView = textView,
              let storage = textView.textStorage,
              let processor = textView.textStorageProcessor else { return }
        guard NotesTextProcessor.hideSyntax else { return }

        let string = storage.string as NSString

        for block in processor.blocks {
            guard case .table = block.type else { continue }
            guard block.range.location < string.length,
                  NSMaxRange(block.range) <= string.length else { continue }

            // Check if already rendered
            if block.range.length == 1,
               let att = storage.attribute(.attachment, at: block.range.location, effectiveRange: nil) as? NSTextAttachment,
               att.attachmentCell is InlineTableAttachmentCell {
                continue
            }

            let tableMarkdown = string.substring(with: block.range)
            guard let data = TableUtility.parse(markdown: tableMarkdown) else { continue }

            let maxWidth = getTableMaxWidth()
            let tableView = InlineTableView()
            tableView.configure(with: data)
            tableView.containerWidth = maxWidth
            tableView.isFocused = false
            tableView.rebuild()

            let attachment = NSTextAttachment()
            let cell = InlineTableAttachmentCell(tableView: tableView, size: tableView.intrinsicContentSize)
            attachment.attachmentCell = cell
            attachment.bounds = NSRect(origin: .zero, size: tableView.intrinsicContentSize)

            let attachmentString = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
            let attRange = NSRange(location: 0, length: attachmentString.length)
            attachmentString.addAttributes([
                .renderedBlockOriginalMarkdown: tableMarkdown,
                .renderedBlockSource: tableMarkdown,
                .renderedBlockType: RenderedBlockType.table.rawValue
            ], range: attRange)

            processor.isRendering = true
            storage.beginEditing()
            storage.replaceCharacters(in: block.range, with: attachmentString)
            processor.isRendering = false
            storage.endEditing()
        }
    }

    // MARK: - Cell Focus

    /// Focus the first editable cell in the most recently added InlineTableView.
    func focusFirstInlineTableCell() {
        guard let textView = textView else { return }
        for subview in textView.subviews.reversed() {
            if let tableView = subview as? InlineTableView {
                tableView.focusState = .editing
                tableView.focusFirstCell()
                if let storage = textView.textStorage, let lm = textView.layoutManager {
                    lm.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
                }
                break
            }
        }
    }

    /// Remove editing focus from all inline table views.
    func unfocusAllInlineTableViews() {
        guard let textView = textView else { return }
        for subview in textView.subviews {
            if let tableView = subview as? InlineTableView, tableView.focusState == .editing {
                tableView.focusState = .unfocused
                tableView.rebuild()
            }
        }
    }

    // MARK: - Inline Cell Formatting

    /// Apply bold/italic markers to the active table cell's field editor.
    /// Returns true if a table cell was active and formatting was applied.
    func applyInlineTableCellFormatting(_ marker: String) -> Bool {
        guard let textView = textView,
              let fieldEditor = textView.window?.fieldEditor(false, for: nil),
              let cell = fieldEditor.delegate as? NSTextField,
              cell.superview is InlineTableView else { return false }

        let sel = fieldEditor.selectedRange
        let nsText = fieldEditor.string as NSString

        if sel.length > 0 {
            let selected = nsText.substring(with: sel)
            if selected.hasPrefix(marker) && selected.hasSuffix(marker) && selected.count > marker.count * 2 {
                let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
                fieldEditor.replaceCharacters(in: sel, with: inner)
                fieldEditor.selectedRange = NSRange(location: sel.location, length: inner.count)
            } else {
                let wrapped = marker + selected + marker
                fieldEditor.replaceCharacters(in: sel, with: wrapped)
                fieldEditor.selectedRange = NSRange(location: sel.location + marker.count, length: sel.length)
            }
        } else {
            let doubleMarker = marker + marker
            fieldEditor.replaceCharacters(in: sel, with: doubleMarker)
            fieldEditor.selectedRange = NSRange(location: sel.location + marker.count, length: 0)
        }
        return true
    }

    // MARK: - Helpers

    func getTableMaxWidth() -> CGFloat {
        if let editorWidth = textView?.enclosingScrollView?.contentView.bounds.width {
            return editorWidth - 40
        }
        return 400
    }
}
