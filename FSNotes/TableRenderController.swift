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

    // NOTE: the former `prepareRenderedTablesForSave()` — which
    // walked every live `InlineTableView`, ran `collectCellData` on
    // it, serialized via `generateMarkdown`, and wrote the result
    // into `.renderedBlockOriginalMarkdown` / `.renderedBlockSource`
    // attributes on the attachment character — has been deleted.
    // It was the post-hoc save-path walker that CLAUDE.md rule 1
    // describes as the cautionary tale for the whole project.
    //
    // All table state now flows through the block-model Document:
    // every cell edit routes through `EditingOps.replaceTableCellInline`
    // (Stage 3), which recomputes `Block.table.raw` on the projection
    // immediately. `MarkdownSerializer.serialize(.table)` reads
    // `raw` directly — no view walk, no attribute round-trip.

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

            // Build a Block.table from the attachment's parsed data.
            // The widget takes the Block as its single source of truth
            // via `configure(withBlock:)` — no more TableUtility.TableData
            // intermediary, no more parallel `headers`/`rows` state that
            // can drift from the Document.
            let block: Block = .table(
                header: tableAtt.header,
                alignments: tableAtt.alignments,
                rows: tableAtt.rows,
                raw: tableAtt.rawMarkdown
            )

            let tableView = InlineTableView()
            tableView.configure(withBlock: block)
            tableView.containerWidth = maxWidth
            tableView.isFocused = false
            tableView.rebuild()

            let cell = InlineTableAttachmentCell(tableView: tableView, size: tableView.intrinsicContentSize)
            tableAtt.attachmentCell = cell
            // TK2 view-provider handoff — `TableBlockAttachment` exposes
            // `liveHostedView` as a weak NSView pointer that
            // `TableAttachmentViewProvider.loadView()` reads. Under TK1
            // this is ignored (cell.draw() still positions the widget);
            // under TK2 this is the path that makes the table visible.
            tableAtt.liveHostedView = tableView
            tableAtt.bounds = NSRect(origin: .zero, size: tableView.intrinsicContentSize)

            // Tag the attachment character with block-type metadata so
            // click-handling / navigation code can identify it. The
            // `.renderedBlockOriginalMarkdown` / `.renderedBlockSource`
            // attributes are NOT written on tables anymore — the Block
            // model is the source of truth, and the serializer reads
            // from Document, not from storage attributes.
            storage.addAttributes([
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
                // Phase 2a: table rendering is an accepted 2a regression
                // under TK2 — the TK1 invalidate call is skipped there.
                if let storage = textView.textStorage, let lm = textView.layoutManagerIfTK1 {
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

    /// Toggle an inline format on the selection inside the active
    /// table cell's field editor by mutating attributes (no marker
    /// text inserted). If the selection already has the trait
    /// uniformly applied, it's removed; otherwise it's added. After
    /// the mutation, the updated attributed string is converted to
    /// an inline tree via `InlineRenderer.inlineTreeFromAttributedString`
    /// and flushed through `EditTextView.applyTableCellInlineEdit`
    /// — field-editor attribute mutations don't fire
    /// `controlTextDidChange`, so the flush is manual.
    ///
    /// Caret-only (no selection): inserts empty format markers and
    /// positions cursor between them for immediate typing.
    func applyInlineTableCellFormat(_ format: InlineCellFormat) -> Bool {
        guard let textView = textView,
              let fieldEditor = textView.window?.fieldEditor(false, for: nil),
              let cell = fieldEditor.delegate as? NSTextField,
              let tableView = findEnclosingTable(cell),
              let tv = fieldEditor as? NSTextView,
              let storage = tv.textStorage else { return false }

        let sel = fieldEditor.selectedRange
        
        // Caret-only: insert format markers and position cursor between them
        if sel.length == 0 {
            return applyCaretOnlyFormatting(format, at: sel.location, in: tv, storage: storage, tableView: tableView, cell: cell)
        }

        toggleTraitAttribute(format, on: storage, range: sel, baseCell: cell)
        fieldEditor.selectedRange = sel

        // Push the new state through the primitive. The field editor's
        // attribute mutation doesn't fire `controlTextDidChange`, so
        // we run the same code path manually: convert the attributed
        // string to an inline tree and call the editor's inline-edit
        // entry point.
        guard let editTextView = findParentEditTextView(for: textView),
              let location = tableView.cellLocation(for: cell) else {
            return true
        }
        let attr = NSAttributedString(attributedString: storage)
        let inline = InlineRenderer.inlineTreeFromAttributedString(attr)
        _ = editTextView.applyTableCellInlineEdit(
            from: tableView,
            at: location,
            inline: inline
        )
        return true
    }
    
    /// Apply formatting when there's no selection - insert format markers
    /// and position cursor between them for immediate typing.
    private func applyCaretOnlyFormatting(
        _ format: InlineCellFormat,
        at location: Int,
        in textView: NSTextView,
        storage: NSTextStorage,
        tableView: InlineTableView,
        cell: NSTextField
    ) -> Bool {
        let openMarker = format.open
        let closeMarker = format.close
        let fullMarker = openMarker + closeMarker
        
        // Insert the markers at caret position
        let markerAttr = NSAttributedString(string: fullMarker)
        storage.insert(markerAttr, at: location)
        
        // Position cursor between the markers
        let newCursorPos = location + openMarker.lengthOfBytes(using: .utf8)
        textView.selectedRange = NSRange(location: newCursorPos, length: 0)
        
        // Push the changes through the primitive
        guard let editTextView = findParentEditTextView(for: self.textView),
              let cellLocation = tableView.cellLocation(for: cell) else {
            return true
        }
        
        let attr = NSAttributedString(attributedString: storage)
        let inline = InlineRenderer.inlineTreeFromAttributedString(attr)
        _ = editTextView.applyTableCellInlineEdit(
            from: tableView,
            at: cellLocation,
            inline: inline
        )
        
        return true
    }

    /// Walk up from a given view to find the hosting EditTextView.
    private func findParentEditTextView(for view: NSView?) -> EditTextView? {
        var current: NSView? = view
        while let v = current {
            if let etv = v as? EditTextView { return etv }
            current = v.superview
        }
        return nil
    }

    /// Toggle a single inline format attribute on the given range of
    /// the field editor's storage. If the selection already has the
    /// trait applied uniformly, remove it; otherwise apply it. The
    /// semantics match how the main text view's `toggleInlineTrait`
    /// behaves on paragraph content — cells are paragraphs.
    private func toggleTraitAttribute(
        _ format: InlineCellFormat,
        on storage: NSTextStorage,
        range: NSRange,
        baseCell: NSTextField
    ) {
        let baseFont = baseCell.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let fm = NSFontManager.shared

        switch format {
        case .bold:
            toggleFontTrait(on: storage, range: range, baseFont: baseFont,
                            add: .boldFontMask, remove: .unboldFontMask,
                            isActive: { fm.traits(of: $0).contains(.boldFontMask) })
        case .italic:
            toggleFontTrait(on: storage, range: range, baseFont: baseFont,
                            add: .italicFontMask, remove: .unitalicFontMask,
                            isActive: { fm.traits(of: $0).contains(.italicFontMask) })
        case .strike:
            toggleScalarAttribute(.strikethroughStyle,
                                  value: NSUnderlineStyle.single.rawValue,
                                  on: storage, range: range)
        case .underline:
            toggleScalarAttribute(.underlineStyle,
                                  value: NSUnderlineStyle.single.rawValue,
                                  on: storage, range: range)
        case .highlight:
            // Shared constant with `InlineRenderer.render(.highlight)`
            // so the converter's round-trip detection recognizes the
            // background color on the way back.
            toggleColorAttribute(.backgroundColor,
                                 value: InlineRenderer.highlightColor,
                                 on: storage, range: range)
        case .code:
            let size = baseFont.pointSize
            let mono = NSFont.userFixedPitchFont(ofSize: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            // Code is a binary: either the whole selection is code
            // or none of it is. Check the first character's font
            // to decide toggle direction.
            let firstFont = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let isActive = firstFont.map {
                $0.fontDescriptor.symbolicTraits.contains(.monoSpace)
            } ?? false
            if isActive {
                storage.addAttribute(.font, value: baseFont, range: range)
            } else {
                storage.addAttribute(.font, value: mono, range: range)
            }
        case .link:
            // Link toggling needs its own flow (dialog for URL, etc.)
            // and is handled by the link-menu path, not this toggle.
            break
        }
    }

    /// Toggle a font trait (bold/italic) on a range by walking font
    /// runs once, collecting `(subRange, font)` pairs, then flipping
    /// the trait in a second loop over the collected pairs (no
    /// second `enumerateAttribute` call). If every run had the trait,
    /// strip it; otherwise add it. Preserves any non-toggled trait
    /// (e.g. toggling italic leaves bold alone).
    private func toggleFontTrait(
        on storage: NSTextStorage,
        range: NSRange,
        baseFont: NSFont,
        add addMask: NSFontTraitMask,
        remove removeMask: NSFontTraitMask,
        isActive: (NSFont) -> Bool
    ) {
        let fm = NSFontManager.shared
        var runs: [(NSRange, NSFont)] = []
        var allActive = true
        storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
            let font = (value as? NSFont) ?? baseFont
            if !isActive(font) { allActive = false }
            runs.append((subRange, font))
        }
        for (subRange, font) in runs {
            let newFont = allActive
                ? fm.convert(font, toNotHaveTrait: addMask)
                : fm.convert(font, toHaveTrait: addMask)
            storage.addAttribute(.font, value: newFont, range: subRange)
        }
    }

    /// Toggle an integer attribute (strikethroughStyle, underlineStyle)
    /// on a range. Active ⇔ every character currently has `value`.
    private func toggleScalarAttribute(
        _ key: NSAttributedString.Key,
        value: Int,
        on storage: NSTextStorage,
        range: NSRange
    ) {
        var allActive = true
        storage.enumerateAttribute(key, in: range, options: []) { v, _, _ in
            if (v as? Int) != value { allActive = false }
        }
        if allActive {
            storage.removeAttribute(key, range: range)
        } else {
            storage.addAttribute(key, value: value, range: range)
        }
    }

    /// Toggle a color attribute on a range. Active ⇔ every character
    /// currently has a color equal to `value` within the tolerance
    /// `InlineRenderer.colorsApproximatelyEqual` uses.
    private func toggleColorAttribute(
        _ key: NSAttributedString.Key,
        value: NSColor,
        on storage: NSTextStorage,
        range: NSRange
    ) {
        var allActive = true
        storage.enumerateAttribute(key, in: range, options: []) { v, _, _ in
            guard let c = v as? NSColor else { allActive = false; return }
            if !InlineRenderer.colorsApproximatelyEqual(c, value) { allActive = false }
        }
        if allActive {
            storage.removeAttribute(key, range: range)
        } else {
            storage.addAttribute(key, value: value, range: range)
        }
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
        guard let tv = textView, let tc = tv.textContainer else { return 400 }
        let pad = tc.lineFragmentPadding
        return max(100, tc.size.width - 2 * pad)
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
        // Phase 2a: table reflow is an accepted 2a regression under TK2.
        guard let textView = textView,
              let storage = textView.textStorage,
              let lm = textView.layoutManagerIfTK1 else { return }

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
