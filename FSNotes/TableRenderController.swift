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

    /// Configure TableBlockAttachment instances with InlineTableView widgets.
    /// In block-model mode, the renderer emits each table as a single
    /// attachment character (TableBlockAttachment). This method walks
    /// storage, finds those attachments, and sets up the live
    /// InlineTableView cell on each one. No text replacement — just
    /// cell configuration on existing attachment characters.
    func renderTables() {
        guard let textView = textView,
              let storage = textView.textStorage else { return }
        guard NotesTextProcessor.hideSyntax else { return }

        let fullRange = NSRange(location: 0, length: storage.length)
        let maxWidth = getTableMaxWidth()

        storage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            guard let tableAtt = value as? TableBlockAttachment else { return }

            // Already configured — skip.
            if tableAtt.attachmentCell is InlineTableAttachmentCell { return }

            // Build TableData from the attachment's parsed data.
            let nsAlignments = tableAtt.alignments.map { align -> NSTextAlignment in
                switch align {
                case .left, .none: return .left
                case .center: return .center
                case .right: return .right
                }
            }
            let data = TableUtility.TableData(
                headers: tableAtt.header,
                rows: tableAtt.rows,
                alignments: nsAlignments
            )

            let tableView = InlineTableView()
            tableView.configure(with: data)
            tableView.containerWidth = maxWidth
            tableView.isFocused = false
            tableView.rebuild()

            let cell = InlineTableAttachmentCell(tableView: tableView, size: tableView.intrinsicContentSize)
            tableAtt.attachmentCell = cell
            tableAtt.bounds = NSRect(origin: .zero, size: tableView.intrinsicContentSize)

            // Tag the attachment character with block metadata for save.
            storage.addAttributes([
                .renderedBlockOriginalMarkdown: tableAtt.rawMarkdown,
                .renderedBlockSource: tableAtt.rawMarkdown,
                .renderedBlockType: RenderedBlockType.table.rawValue
            ], range: range)
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
