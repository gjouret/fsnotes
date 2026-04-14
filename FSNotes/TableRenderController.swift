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

    /// The kind of inline formatting that can be applied to a table cell.
    /// Each kind knows (a) its markdown open/close markers and (b) the
    /// visual NSAttributedString style to apply to the field editor's
    /// inner range for immediate live-render feedback.
    enum InlineCellFormat {
        case bold
        case italic
        case strike
        case underline
        case highlight
        case code
        case link(url: String)

        var open: String {
            switch self {
            case .bold: return "**"
            case .italic: return "*"
            case .strike: return "~~"
            case .underline: return "<u>"
            case .highlight: return "<mark>"
            case .code: return "`"
            case .link: return "["
            }
        }

        var close: String {
            switch self {
            case .bold: return "**"
            case .italic: return "*"
            case .strike: return "~~"
            case .underline: return "</u>"
            case .highlight: return "</mark>"
            case .code: return "`"
            case .link(let url): return "](\(url))"
            }
        }
    }

    /// Apply the symmetric-marker wrap path (bold/italic/strike — i.e. the
    /// legacy shape with equal open/close markers). Preserved for existing
    /// callers that still pass a plain string marker.
    func applyInlineTableCellFormatting(_ marker: String) -> Bool {
        let format: InlineCellFormat
        switch marker {
        case "**": format = .bold
        case "*":  format = .italic
        case "~~": format = .strike
        case "`":  format = .code
        default:   return false
        }
        return applyInlineTableCellFormat(format)
    }

    /// Apply any supported inline format to the active table cell's field
    /// editor: wraps/unwraps the selection with the format's open/close
    /// markers, repositions the selection, applies visual attributes for
    /// immediate Live-Preview feedback, and synthesizes the change
    /// notification so the InlineTableView's data model + save path pick
    /// up the edit. Returns true if a table cell was active.
    func applyInlineTableCellFormat(_ format: InlineCellFormat) -> Bool {
        guard let textView = textView,
              let fieldEditor = textView.window?.fieldEditor(false, for: nil),
              let cell = fieldEditor.delegate as? NSTextField,
              let tableView = findEnclosingTable(cell) else { return false }

        let open = format.open
        let close = format.close
        let sel = fieldEditor.selectedRange
        let nsText = fieldEditor.string as NSString

        // Resulting inner range in the field editor AFTER mutation — used
        // below to apply visual attributes (bold, italic, underline, ...)
        // so the user sees formatted text immediately rather than raw
        // markdown markers.
        var innerRange = NSRange(location: NSNotFound, length: 0)
        var didUnwrap = false

        // Ranges of the open/close markers in the field editor AFTER
        // mutation, used below to visually hide the markers so the cell
        // shows rendered text immediately (no raw `**` / `<u>` / etc.
        // fences while the user is still inside the cell).
        var openMarkerRange = NSRange(location: NSNotFound, length: 0)
        var closeMarkerRange = NSRange(location: NSNotFound, length: 0)

        if sel.length > 0 {
            let selected = nsText.substring(with: sel)
            if selected.hasPrefix(open) && selected.hasSuffix(close) && selected.count > open.count + close.count {
                // Unwrap.
                let inner = String(selected.dropFirst(open.count).dropLast(close.count))
                fieldEditor.replaceCharacters(in: sel, with: inner)
                fieldEditor.selectedRange = NSRange(location: sel.location, length: inner.count)
                didUnwrap = true
            } else {
                // Wrap.
                let wrapped = open + selected + close
                fieldEditor.replaceCharacters(in: sel, with: wrapped)
                fieldEditor.selectedRange = NSRange(location: sel.location + open.count, length: sel.length)
                innerRange = NSRange(location: sel.location + open.count, length: sel.length)
                openMarkerRange = NSRange(location: sel.location, length: (open as NSString).length)
                closeMarkerRange = NSRange(location: sel.location + open.count + sel.length, length: (close as NSString).length)
            }
        } else {
            // Caret-only: insert open+close and park the caret between them.
            let both = open + close
            fieldEditor.replaceCharacters(in: sel, with: both)
            fieldEditor.selectedRange = NSRange(location: sel.location + open.count, length: 0)
            openMarkerRange = NSRange(location: sel.location, length: (open as NSString).length)
            closeMarkerRange = NSRange(location: sel.location + open.count, length: (close as NSString).length)
        }

        // Live visual rendering on the field editor. The field editor is
        // an NSTextView; applying attributes to its textStorage shows up
        // immediately. We (a) style the inner range with the target format
        // (bold / italic / …) and (b) collapse the open/close markers to
        // near-zero width so the cell shows rendered text like the
        // non-editing state — no raw `**` fences visible while typing.
        // The underlying plain string still contains the markers, so
        // collectCellData() + notifyChanged() serialize correct markdown.
        if !didUnwrap,
           let tv = fieldEditor as? NSTextView,
           let storage = tv.textStorage {
            if innerRange.location != NSNotFound, innerRange.length > 0 {
                applyLiveAttributes(for: format, to: storage, range: innerRange, baseCell: cell)
            }
            hideMarker(in: storage, range: openMarkerRange)
            hideMarker(in: storage, range: closeMarkerRange)
        }

        // Programmatic `replaceCharacters` on the field editor does NOT
        // fire `controlTextDidChange`, so the InlineTableView's data
        // model never sees the new text. Synthesize the notification
        // so collectCellData + recalculate + notifyChanged run exactly
        // as if the user had typed the characters themselves.
        let note = Notification(name: NSControl.textDidChangeNotification, object: cell)
        tableView.controlTextDidChange(note)
        return true
    }

    /// Apply visual attributes to the field editor's textStorage to
    /// preview the formatting that was just wrapped into markdown. Uses
    /// the base cell's current font as the starting point so italic/bold
    /// traits layer correctly on whatever the cell inherited.
    private func applyLiveAttributes(
        for format: InlineCellFormat,
        to storage: NSTextStorage,
        range: NSRange,
        baseCell: NSTextField
    ) {
        let baseFont = baseCell.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let fm = NSFontManager.shared
        switch format {
        case .bold:
            let f = fm.convert(baseFont, toHaveTrait: .boldFontMask)
            storage.addAttribute(.font, value: f, range: range)
        case .italic:
            let f = fm.convert(baseFont, toHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: f, range: range)
        case .strike:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .underline:
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .highlight:
            storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: range)
        case .code:
            let size = baseFont.pointSize
            let mono = NSFont.userFixedPitchFont(ofSize: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            storage.addAttribute(.font, value: mono, range: range)
            storage.addAttribute(.backgroundColor, value: NSColor.secondaryLabelColor.withAlphaComponent(0.15), range: range)
        case .link:
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
    }

    /// Collapse a run of marker characters to near-zero visual width.
    /// The characters stay in the field editor's plain string (so that
    /// `collectCellData()` and `generateMarkdown()` still see them), but
    /// are drawn with a tiny transparent font — effectively invisible.
    /// This matches the non-editing cell appearance where markdown
    /// markers are stripped by `parseInlineMarkdown`.
    private func hideMarker(in storage: NSTextStorage, range: NSRange) {
        guard range.location != NSNotFound,
              range.length > 0,
              NSMaxRange(range) <= storage.length else { return }
        let tinyFont = NSFont.systemFont(ofSize: 0.01)
        storage.addAttribute(.font, value: tinyFont, range: range)
        storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
    }

    /// Walk up the view hierarchy to locate the owning InlineTableView.
    /// Cell.superview is typically `gridDocumentView` (inside an
    /// NSScrollView inside InlineTableView), so we can't trust a
    /// single-level `superview is InlineTableView` check.
    private func findEnclosingTable(_ view: NSView) -> InlineTableView? {
        var v: NSView? = view.superview
        while let current = v {
            if let table = current as? InlineTableView { return table }
            v = current.superview
        }
        return nil
    }

    // MARK: - Helpers

    func getTableMaxWidth() -> CGFloat {
        if let editorWidth = textView?.enclosingScrollView?.contentView.bounds.width {
            return editorWidth - 40
        }
        return 400
    }

    /// Called when the editor/window is resized. Updates each live
    /// InlineTableView's containerWidth so the grid reflows to fit the new
    /// available width, then resizes the hosting attachment cell and
    /// invalidates layout around each table.
    ///
    /// This is the only place that handles "window width changed" for
    /// tables — `renderTables()` configures cells once and skips any
    /// attachment that already has an InlineTableAttachmentCell.
    func reflowTablesForWidthChange() {
        guard let textView = textView,
              let storage = textView.textStorage,
              let lm = textView.layoutManager else { return }

        let newWidth = getTableMaxWidth()
        guard newWidth > 0 else { return }

        let fullRange = NSRange(location: 0, length: storage.length)
        var didChange = false

        storage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            guard let att = value as? NSTextAttachment,
                  let cell = att.attachmentCell as? InlineTableAttachmentCell else { return }

            let tableView = cell.inlineTableView
            // Skip if width is effectively unchanged (within 1pt)
            if abs(tableView.containerWidth - newWidth) < 1.0 { return }

            tableView.containerWidth = newWidth
            tableView.rebuild()
            att.bounds = NSRect(origin: .zero, size: tableView.intrinsicContentSize)
            didChange = true

            lm.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }

        if didChange {
            textView.needsDisplay = true
        }
    }
}
